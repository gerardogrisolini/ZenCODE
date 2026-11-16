//
//  SwiftFeaturePromotion+Publication.swift
//  ZenCODE
//
//  Publication support of feature promotion: the Git checkout of the target,
//  the publication lock and the rollback of a failed publication.
//

import Foundation
import ToolCore
import ZenPackageMetadata
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SwiftFeatureRuntime {
    struct PromotionGitCheckout: Sendable {
        let root: URL
        let branch: String?
        let commonDirectory: URL
    }

    enum PromotionCatalogBackup: Sendable {
        case absent
        case contents(Data)
    }

    static func rollbackPromotionPublication(
        fileManager: FileManager,
        destinationURL: URL,
        destinationExisted: Bool,
        destinationBackupURL: URL,
        published: Bool,
        catalogBackups: [URL: PromotionCatalogBackup]
    ) throws {
        if published, fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        if destinationExisted, fileManager.fileExists(atPath: destinationBackupURL.path) {
            try fileManager.moveItem(at: destinationBackupURL, to: destinationURL)
        }
        for (url, backup) in catalogBackups {
            switch backup {
            case .contents(let data):
                try data.write(to: url, options: [.atomic])
            case .absent:
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
        let lockURL = gitCommonDirectoryURL.appendingPathComponent("zencode-feature-promotion.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DirectToolError.persistenceFailed("Could not open promotion lock: \(lockURL.path).")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw DirectToolError.persistenceFailed(
                "Another feature promotion is publishing in this checkout."
            )
        }
        return descriptor
    }

    func releasePromotionPublicationLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
#else
    func acquirePromotionPublicationLock(gitCommonDirectoryURL: URL) throws -> Int32 {
        _ = gitCommonDirectoryURL
        throw DirectToolError.permissionDenied("Feature promotion locking is unavailable on this platform.")
    }

    func releasePromotionPublicationLock(_ descriptor: Int32) { _ = descriptor }
#endif

#if canImport(Darwin) || canImport(Glibc)
    func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
        let rootResult = try await runPromotionGit(["rev-parse", "--show-toplevel"], at: url)
        guard rootResult.exitCode == 0 else {
            throw DirectToolError.permissionDenied("The promotion target is not a Git checkout: \(url.path).")
        }
        let rootPath = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            throw DirectToolError.permissionDenied("Git did not return a checkout root for \(url.path).")
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let commonDirectoryResult = try await runPromotionGit(["rev-parse", "--git-common-dir"], at: root)
        guard commonDirectoryResult.exitCode == 0,
              let commonDirectoryPath = commonDirectoryResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw DirectToolError.permissionDenied("Git did not return its common directory for \(root.path).")
        }
        let commonDirectory = (commonDirectoryPath.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirectoryPath, isDirectory: true)
            : root.appendingPathComponent(commonDirectoryPath, isDirectory: true))
            .standardizedFileURL
        let branchResult = try await runPromotionGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch = branchResult.exitCode == 0
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            : nil
        return PromotionGitCheckout(root: root, branch: branch, commonDirectory: commonDirectory)
    }

    func runPromotionGit(_ arguments: [String], at directory: URL) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            workingDirectory: directory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 30
        )
    }
#else
    func requirePromotionGitCheckout(at url: URL) async throws -> PromotionGitCheckout {
        _ = url
        throw DirectToolError.permissionDenied("Git-backed feature promotion is unavailable on this platform.")
    }
#endif
}
