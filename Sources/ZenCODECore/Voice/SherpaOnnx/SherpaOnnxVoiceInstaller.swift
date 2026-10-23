//
//  SherpaOnnxVoiceInstaller.swift
//  ZenCODE
//
//  Downloads, verifies and installs the pinned Linux voice-mode files.
//  Every file is streamed into a private staging directory while its SHA-256
//  is computed, checked against the pinned size and checksum, unpacked with
//  the system `tar` when it is an archive, and only then moved into place.
//  A failure at any step leaves the previous installation untouched.
//

import Crypto
import Dispatch
import Foundation

/// Streams a download. Production uses `SherpaOnnxHTTPDownloader`; tests
/// inject local data.
protocol SherpaOnnxAssetDownloading: Sendable {
    /// Delivers the body of `url` to `onChunk`, refusing more than
    /// `maximumByteCount` bytes.
    func download(
        _ url: URL,
        maximumByteCount: Int64,
        onChunk: (Data) throws -> Void
    ) async throws
}

/// HTTPS download over the shared SwiftNIO transport. GitHub release
/// downloads redirect to a signed storage URL, so redirects are followed
/// (HTTPS only, bounded); a body that stalls for a minute is aborted.
struct SherpaOnnxHTTPDownloader: SherpaOnnxAssetDownloading {
    static let maximumRedirects = 5
    static let idleTimeoutNanoseconds: UInt64 = 60 * 1_000_000_000

    let transport: RemoteTransportCore

    init(transport: RemoteTransportCore = RemoteTransportCore()) {
        self.transport = transport
    }

    func download(
        _ url: URL,
        maximumByteCount: Int64,
        onChunk: (Data) throws -> Void
    ) async throws {
        var currentURL = url
        for _ in 0...Self.maximumRedirects {
            let response = try await transport.openHTTPStream(
                RemoteHTTPStreamingRequest(url: currentURL, timeout: .seconds(60))
            )
            switch response.status {
            case 301, 302, 303, 307, 308:
                response.body.cancel()
                guard let location = response.headers.firstValue(for: "location"),
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                      next.scheme?.lowercased() == "https" else {
                    throw RemoteTransportError.protocolViolation(
                        "Invalid HTTP redirect while downloading \(url.lastPathComponent)."
                    )
                }
                currentURL = next
            case 200..<300:
                var iterator = response.body.makeAsyncIterator()
                var received: Int64 = 0
                while let chunk = try await iterator.next(
                    idleTimeoutNanoseconds: Self.idleTimeoutNanoseconds
                ) {
                    received += Int64(chunk.count)
                    guard received <= maximumByteCount else {
                        response.body.cancel()
                        throw SherpaOnnxVoiceInstallError.sizeMismatch(
                            fileName: url.lastPathComponent,
                            expected: maximumByteCount,
                            actual: received
                        )
                    }
                    try onChunk(chunk)
                }
                return
            default:
                response.body.cancel()
                throw SherpaOnnxVoiceInstallError.httpStatus(response.status)
            }
        }
        throw RemoteTransportError.protocolViolation(
            "Too many HTTP redirects while downloading \(url.lastPathComponent)."
        )
    }
}

struct SherpaOnnxVoiceInstaller: Sendable {
    enum Step: Sendable, Equatable {
        case downloading(SherpaOnnxAsset, receivedBytes: Int64)
        case unpacking(SherpaOnnxAsset)
        case installed(SherpaOnnxAsset)
    }

    static let bzip2Candidates = [
        "/usr/bin/bzip2",
        "/bin/bzip2",
        "/usr/local/bin/bzip2",
        "/opt/homebrew/bin/bzip2"
    ]

    let installation: SherpaOnnxVoiceInstallation
    let downloader: any SherpaOnnxAssetDownloading

    init(
        installation: SherpaOnnxVoiceInstallation,
        downloader: any SherpaOnnxAssetDownloading = SherpaOnnxHTTPDownloader()
    ) {
        self.installation = installation
        self.downloader = downloader
    }

    /// Installs every missing file `voice` needs, then removes any other
    /// installed voice so exactly one voice remains.
    func install(
        voice: SherpaOnnxVoice,
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws {
        guard let missing = installation.missingAssets(for: voice) else {
            throw SherpaOnnxVoiceInstallError.unsupportedArchitecture
        }
        if missing.contains(where: { $0.kind != .file }) {
            try Self.checkUnpackingTools()
        }
        try? FileManager.default.removeItem(at: installation.stagingDirectoryURL)
        for asset in missing {
            try await install(asset, progress: progress)
        }
        try removeVoices(except: voice)
    }

    /// Downloads, verifies and installs one asset, replacing an existing copy.
    func install(
        _ asset: SherpaOnnxAsset,
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws {
        let fileManager = FileManager.default
        let staging = installation.stagingDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
            if let remaining = try? fileManager.contentsOfDirectory(
                atPath: installation.stagingDirectoryURL.path
            ), remaining.isEmpty {
                try? fileManager.removeItem(at: installation.stagingDirectoryURL)
            }
        }

        let downloadURL = staging.appendingPathComponent(asset.fileName)
        guard fileManager.createFile(atPath: downloadURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: downloadURL.path])
        }
        let handle = try FileHandle(forWritingTo: downloadURL)
        var hasher = SHA256()
        var received: Int64 = 0
        do {
            try await downloader.download(asset.url, maximumByteCount: asset.byteCount) { chunk in
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                received += Int64(chunk.count)
                progress(.downloading(asset, receivedBytes: received))
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard received == asset.byteCount else {
            throw SherpaOnnxVoiceInstallError.sizeMismatch(
                fileName: asset.fileName,
                expected: asset.byteCount,
                actual: received
            )
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            throw SherpaOnnxVoiceInstallError.checksumMismatch(fileName: asset.fileName)
        }

        let source: URL
        switch asset.kind {
        case .file:
            source = downloadURL
        case let .archive(directoryName):
            progress(.unpacking(asset))
            let unpackURL = staging.appendingPathComponent("unpacked", isDirectory: true)
            try fileManager.createDirectory(at: unpackURL, withIntermediateDirectories: true)
            try await Self.unpack(archive: downloadURL, into: unpackURL, fileName: asset.fileName)
            source = unpackURL.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SherpaOnnxVoiceInstallError.unexpectedLayout(asset.fileName)
            }
        }

        let destination = installation.installedURL(for: asset)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        progress(.installed(asset))
    }

    func removeVoices(except kept: SherpaOnnxVoice) throws {
        for voice in installation.installedVoices() where voice != kept {
            try FileManager.default.removeItem(at: installation.installedURL(for: voice.asset))
        }
    }

    /// Deletes every downloaded voice-mode file.
    func removeAll() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installation.directoryURL.path) else {
            return
        }
        try fileManager.removeItem(at: installation.directoryURL)
    }

    /// `tar` and `bzip2` unpack the `.tar.bz2` archives; both are checked
    /// before anything is downloaded.
    static func checkUnpackingTools(fileManager: FileManager = .default) throws {
        guard SupportDirectoryArchive.locateTarExecutable(fileManager: fileManager) != nil else {
            throw SherpaOnnxVoiceInstallError.missingTool("tar")
        }
        guard bzip2Candidates.contains(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw SherpaOnnxVoiceInstallError.missingTool("bzip2")
        }
    }

    /// Runs the blocking `tar` off the cooperative thread pool.
    static func unpack(archive: URL, into destination: URL, fileName: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try SupportDirectoryArchive.runTar(
                        ["--no-same-owner", "-xjf", archive.path, "-C", destination.path],
                        fileManager: .default
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SherpaOnnxVoiceInstallError.extractionFailed(
                        fileName: fileName,
                        reason: error.localizedDescription
                    ))
                }
            }
        }
    }
}
