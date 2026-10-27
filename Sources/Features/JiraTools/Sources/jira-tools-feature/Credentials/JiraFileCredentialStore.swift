import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// File-backed Jira API token store, the credential backend on every platform
/// (macOS included, so headless runs such as `/cron` jobs can read the token).
/// Tokens live in
/// `<support dir>/jira/credentials/<percent-encoded account>.token`
/// with `0600` permissions inside a `0700` directory.
struct JiraFileCredentialStore: Sendable {
    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = (directoryURL ?? Self.defaultDirectoryURL()).standardizedFileURL
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        JiraFeatureStorageDirectory
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("jira", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: true)
    }

    /// Derives a filesystem-safe file name: every character outside
    /// `[A-Za-z0-9]` is percent-encoded, so no separator, dot or traversal
    /// sequence can survive.
    static func fileName(forAccount account: String) -> String {
        let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return (encoded.isEmpty ? "%00" : encoded) + ".token"
    }

    func fileURL(account: String) -> URL {
        directoryURL.appendingPathComponent(Self.fileName(forAccount: account), isDirectory: false)
    }

    func load(account: String, fileManager: FileManager = .default) throws -> String {
        let url = fileURL(account: account)
        guard fileManager.fileExists(atPath: url.path) else { throw JiraToolsError.missingCredentials }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw JiraToolsError.invalidConfiguration("Unable to read the Jira API token file at \(url.path).")
        }
        guard let token = String(validating: data, as: UTF8.self)?.nilIfBlank else {
            throw JiraToolsError.invalidConfiguration(
                "Jira API token file at \(url.path) is empty or not valid UTF-8 text."
            )
        }
        return token
    }

    func save(_ apiToken: String, account: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let finalURL = fileURL(account: account)
        let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try Self.writeExclusively(Data(apiToken.utf8), to: temporaryURL.path)
            guard rename(temporaryURL.path, finalURL.path) == 0 else {
                throw JiraToolsError.invalidConfiguration(
                    "Unable to store the Jira API token at \(finalURL.path) (errno \(errno))."
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
    }

    func remove(account: String, fileManager: FileManager = .default) throws {
        let url = fileURL(account: account)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                throw JiraToolsError.invalidConfiguration("Unable to remove the Jira API token file at \(url.path).")
            }
        }
    }

    private static func writeExclusively(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw JiraToolsError.invalidConfiguration(
                "Unable to create the Jira API token file at \(path) (errno \(errno))."
            )
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
                    throw JiraToolsError.invalidConfiguration(
                        "Unable to write the Jira API token file at \(path) (errno \(errno))."
                    )
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw JiraToolsError.invalidConfiguration(
                "Unable to flush the Jira API token file at \(path) (errno \(errno))."
            )
        }
        succeeded = true
    }
}

/// Jira configuration supplied through environment variables (used on
/// platforms without the browser setup form).
enum JiraEnvironmentConfiguration {
    static let siteURLKey = "ZENCODE_JIRA_SITE_URL"
    static let emailKey = "ZENCODE_JIRA_EMAIL"
    static let apiTokenKey = "ZENCODE_JIRA_API_TOKEN"
    static let allKeys = [siteURLKey, emailKey, apiTokenKey]

    static func resolve(
        environment: [String: String]
    ) throws -> (configuration: JiraStoredConfiguration, apiToken: String)? {
        func value(_ key: String) -> String? {
            environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        let site = value(siteURLKey)
        let email = value(emailKey)
        let token = value(apiTokenKey)

        if site == nil, email == nil, token == nil {
            return nil
        }
        guard let site, let email, let token else {
            let missing = allKeys.filter { value($0) == nil }
            throw JiraToolsError.environmentConfigurationRequired(missing: missing)
        }
        let configuration = try JiraStoredConfiguration(siteURLString: site, email: email)
        return (configuration, token)
    }
}
