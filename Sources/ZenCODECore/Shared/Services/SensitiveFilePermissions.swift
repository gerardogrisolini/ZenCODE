//
//  SensitiveFilePermissions.swift
//  ZenCODE
//
//  Created by ZenCODE on 18/06/26.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Centralizes the filesystem boundary for manifests that contain credentials
/// or durable authorization decisions. A future platform credential-vault
/// migration can replace this boundary without changing the manifest format.
enum SensitiveFilePermissions {
    private static let directoryPermissions = NSNumber(value: 0o700)
    private static let filePermissions = NSNumber(value: 0o600)

    /// Restricts an existing sensitive file before it is read. This performs
    /// the permissions-only migration for manifests written by older releases.
    /// Symbolic links and unexpected node types fail closed: following one here
    /// could chmod an unrelated target before the manifest is decoded.
    static func hardenExistingFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        guard let kind = try existingPathKind(at: url) else {
            return
        }
        guard kind == .regularFile else {
            throw SensitiveFilePermissionsError.unsafePath(
                url,
                expected: "a regular file"
            )
        }
        try hardenDirectory(at: url.deletingLastPathComponent(), fileManager: fileManager)
        try hardenFile(at: url, fileManager: fileManager)
        #else
        _ = url
        _ = fileManager
        #endif
    }

    /// Writes a sensitive manifest with restrictive Unix modes. On POSIX
    /// platforms, the temporary file is mode 0600 before any bytes are written
    /// and is atomically renamed into place after synchronization.
    static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        try hardenDirectory(at: directoryURL, fileManager: fileManager)

        #if canImport(Darwin) || canImport(Glibc)
        // Refuse a pre-existing link rather than chmod-ing it or replacing it.
        // A normal previous manifest is replaced atomically below.
        if let existingKind = try existingPathKind(at: url), existingKind != .regularFile {
            throw SensitiveFilePermissionsError.unsafePath(
                url,
                expected: "a regular file"
            )
        }

        let temporaryURL = temporaryURL(for: url, in: directoryURL)
        do {
            try writeSecureTemporaryFile(data, to: temporaryURL, fileManager: fileManager)
            // rename(2) preserves the already-verified 0600 temporary inode.
            // Keep it as the final fallible operation so a normal write error
            // always means the destination was left unchanged.
            try replaceItem(at: url, with: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    /// Transactional writers additionally order the published directory entry.
    /// This barrier may fail after replacement; their journal/CAS protocol is
    /// responsible for resolving that explicitly.
    static func writeDurably(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default,
        directorySynchronizer: ((URL) throws -> Void)? = nil
    ) throws {
        try write(data, to: url, fileManager: fileManager)
        #if canImport(Darwin) || canImport(Glibc)
        try (directorySynchronizer ?? synchronizeDirectory)(
            url.deletingLastPathComponent()
        )
        #endif
    }

    private static func hardenDirectory(
        at url: URL,
        fileManager: FileManager
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        if let existingKind = try existingPathKind(at: url) {
            guard existingKind == .directory else {
                throw SensitiveFilePermissionsError.unsafePath(
                    url,
                    expected: "a directory"
                )
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            guard try existingPathKind(at: url) == .directory else {
                throw SensitiveFilePermissionsError.unsafePath(
                    url,
                    expected: "a directory"
                )
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
        #else
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private enum PathKind: Equatable {
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    private static func existingPathKind(at url: URL) throws -> PathKind? {
        var metadata = stat()
        let result = url.path.withCString { path in
            #if canImport(Darwin)
            Darwin.lstat(path, &metadata)
            #elseif canImport(Glibc)
            Glibc.lstat(path, &metadata)
            #endif
        }
        guard result == 0 else {
            let errorCode = errno
            if errorCode == ENOENT {
                return nil
            }
            throw SensitiveFilePermissionsError.pathInspectionFailed(
                url,
                errorCode: errorCode
            )
        }

        let type = metadata.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFREG) {
            return .regularFile
        }
        if type == mode_t(S_IFDIR) {
            return .directory
        }
        if type == mode_t(S_IFLNK) {
            return .symbolicLink
        }
        return .other
    }

    private static func hardenFile(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard try existingPathKind(at: url) == .regularFile else {
            throw SensitiveFilePermissionsError.unsafePath(
                url,
                expected: "a regular file"
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: url.path
        )
    }

    private static func temporaryURL(for destinationURL: URL, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
    }

    private static func writeSecureTemporaryFile(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let descriptor = url.path.withCString { path in
            #if canImport(Darwin)
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            #elseif canImport(Glibc)
            Glibc.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            #endif
        }
        guard descriptor >= 0 else {
            throw SensitiveFilePermissionsError.temporaryFileCreationFailed(
                url,
                errorCode: errno
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // Normalize before writing because a process umask may have made the
            // file more restrictive, but must never make it less restrictive.
            try hardenFile(at: url, fileManager: fileManager)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private static func replaceItem(
        at destinationURL: URL,
        with temporaryURL: URL
    ) throws {
        let result = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                #if canImport(Darwin)
                Darwin.rename(temporaryPath, destinationPath)
                #elseif canImport(Glibc)
                Glibc.rename(temporaryPath, destinationPath)
                #endif
            }
        }

        guard result == 0 else {
            throw SensitiveFilePermissionsError.atomicReplacementFailed(
                destinationURL,
                errorCode: errno
            )
        }
    }

    /// Makes prior renames/unlinks in a directory durable and ordered. Callers
    /// use byte-level CAS when this throws after a rename has become visible.
    static func synchronizeDirectory(at directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString { path in
            #if canImport(Darwin)
            Darwin.open(path, O_RDONLY)
            #elseif canImport(Glibc)
            Glibc.open(path, O_RDONLY | O_DIRECTORY)
            #endif
        }
        guard descriptor >= 0 else {
            throw SensitiveFilePermissionsError.directorySyncFailed(
                directoryURL,
                errorCode: errno
            )
        }
        defer { _ = close(descriptor) }

        var result: Int32
        repeat {
            #if canImport(Darwin)
            result = Darwin.fsync(descriptor)
            #elseif canImport(Glibc)
            result = Glibc.fsync(descriptor)
            #endif
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw SensitiveFilePermissionsError.directorySyncFailed(
                directoryURL,
                errorCode: errno
            )
        }
    }
    #endif
}

enum SensitiveFilePermissionsError: LocalizedError {
    case unsafePath(URL, expected: String)
    case pathInspectionFailed(URL, errorCode: Int32)
    case temporaryFileCreationFailed(URL, errorCode: Int32)
    case atomicReplacementFailed(URL, errorCode: Int32)
    case directorySyncFailed(URL, errorCode: Int32)

    var errorDescription: String? {
        switch self {
        case let .unsafePath(url, expected):
            return "Refusing unsafe sensitive path \(url.path); expected \(expected)."
        case let .pathInspectionFailed(url, errorCode):
            return "Unable to inspect private path \(url.path) (POSIX error \(errorCode))."
        case let .temporaryFileCreationFailed(url, errorCode):
            return "Unable to create a private temporary file for \(url.path) (POSIX error \(errorCode))."
        case let .atomicReplacementFailed(url, errorCode):
            return "Unable to replace private file \(url.path) (POSIX error \(errorCode))."
        case let .directorySyncFailed(url, errorCode):
            return "Unable to synchronize private directory \(url.path) (POSIX error \(errorCode))."
        }
    }
}
