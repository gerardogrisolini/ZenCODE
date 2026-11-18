//
//  FigmaCredentialStore.swift
//  ZenCODE
//
//  File-backed store of the Figma login. Only the login flow writes it:
//  `<support>/figma/credentials/login.json`, 0600 inside a 0700 directory,
//  written atomically. Nothing reads credentials from the environment.
//

import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The signed-in Figma account and the access token verified at login.
struct FigmaStoredCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let accountHandle: String?
    let accountEmail: String?
    let signedInAt: Date

    /// Human-readable account label; never contains the token.
    var accountLabel: String {
        var label = accountHandle?.nilIfBlank ?? "Figma user"
        if let email = accountEmail?.nilIfBlank {
            label += " <\(email)>"
        }
        return label
    }
}

struct FigmaCredentialStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    init(environment: [String: String]) {
        self.init(fileURL: FigmaStorage.credentialFileURL(environment: environment))
    }

    /// Returns the stored login, `nil` when nobody is signed in. A store that
    /// is unreadable, corrupt, or accessible to other users is reported as
    /// `invalidCredentialStore`, which makes the caller sign in again.
    func load(fileManager: FileManager = .default) throws -> FigmaStoredCredential? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        if let permissions = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw FigmaToolsError.invalidCredentialStore("the login file is accessible to other users")
        }
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            throw FigmaToolsError.invalidCredentialStore("the login file cannot be read")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let credential = try? decoder.decode(FigmaStoredCredential.self, from: data),
              FigmaCredentialStore.isWellFormedToken(credential.accessToken) else {
            throw FigmaToolsError.invalidCredentialStore("the login file is corrupt")
        }
        return credential
    }

    func save(_ credential: FigmaStoredCredential, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FigmaStorage.createPrivateDirectory(directory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credential)

        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try Self.writeExclusively(data, to: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw FigmaToolsError.invalidCredentialStore("unable to store the login (errno \(errno))")
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Deletes the stored login. Returns `false` when nobody was signed in.
    @discardableResult
    func remove(fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            if fileManager.fileExists(atPath: fileURL.path) {
                throw FigmaToolsError.invalidCredentialStore("unable to remove the login file")
            }
        }
        return true
    }

    /// Printable ASCII without spaces, so the token cannot split HTTP headers.
    static func isWellFormedToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.count <= 4_096
            && token.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    private static func writeExclusively(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw FigmaToolsError.invalidCredentialStore("unable to create the login file (errno \(errno))")
        }
        var succeeded = false
        defer {
            _ = close(descriptor)
            if !succeeded {
                _ = unlink(path)
            }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FigmaToolsError.invalidCredentialStore("unable to write the login file (errno \(errno))")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw FigmaToolsError.invalidCredentialStore("unable to flush the login file (errno \(errno))")
        }
        succeeded = true
    }
}
