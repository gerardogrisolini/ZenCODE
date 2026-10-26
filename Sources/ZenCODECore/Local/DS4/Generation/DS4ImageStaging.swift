//
//  DS4ImageStaging.swift
//  ZenCODE
//
//  Temporary image files of one DS4 generation round. The engine encodes images
//  from files (`zencode_ds4_engine_vision_encode_file`), while ZenCODE keeps
//  the images of a conversation as `image_url` content items (data URLs).
//  `DS4ImageStaging` decodes each image into `<support>/ds4/tmp/<UUID>.<ext>`
//  (directory 0700, files 0600) the first time the renderer asks for it, hands
//  out the same file for the same image during the round, and deletes every
//  file with `removeAll()`: the round calls it as soon as the engine operation
//  that encodes the images ends, on success, error and cancellation alike.
//  Files left behind by a crash are swept (older than one hour) the first time
//  a directory is used in the process.
//

import Foundation
import Synchronization

final class DS4ImageStaging: DS4ImageFileResolving, Sendable {
    /// Age after which a leftover file of a previous run is deleted.
    static let staleFileAge: TimeInterval = 3600
    /// Longest file extension kept from the source image.
    private static let maximumExtensionLength = 8

    private struct State {
        /// `image_url` -> staged file.
        var files: [String: URL] = [:]
        /// Every file this instance created, in creation order.
        var created: [URL] = []
        /// `image_url`s that could not be staged.
        var failed: Set<String> = []
        /// How many of `failed` `takeNewFailureCount()` already reported.
        var reportedFailureCount = 0
        var isDirectoryReady = false
    }

    /// Directories already swept for stale files in this process.
    private static let sweptDirectories = Mutex<Set<String>>([])

    let directory: URL
    private let state = Mutex(State())

    /// `<support>/ds4/tmp`
    static func directory(supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()) -> URL {
        DS4EngineLibraryLocator.ds4Directory(supportDirectory: supportDirectory)
            .appendingPathComponent("tmp", isDirectory: true)
    }

    init(directory: URL = DS4ImageStaging.directory()) {
        self.directory = directory
    }

    deinit {
        removeAll()
    }

    /// Files currently staged (not yet removed).
    var stagedFiles: [URL] {
        state.withLock { $0.created }
    }

    /// Distinct images that could not be staged (undecodable data URL,
    /// unreadable file, unsupported scheme).
    var failedImageCount: Int {
        state.withLock { $0.failed.count }
    }

    /// Images that failed to stage since the previous call (0 when none).
    func takeNewFailureCount() -> Int {
        state.withLock { state in
            let new = state.failed.count - state.reportedFailureCount
            state.reportedFailureCount = state.failed.count
            return new
        }
    }

    // MARK: DS4ImageFileResolving

    func imageFile(forImageURL imageURL: String) -> URL? {
        enum Lookup {
            case staged(URL)
            case failed
            case unknown
        }
        let lookup = state.withLock { state -> Lookup in
            if let url = state.files[imageURL] {
                return .staged(url)
            }
            return state.failed.contains(imageURL) ? .failed : .unknown
        }
        switch lookup {
        case let .staged(url):
            return url
        case .failed:
            return nil
        case .unknown:
            break
        }
        let staged = stage(imageURL)
        state.withLock { state in
            if let staged {
                state.files[imageURL] = staged
                state.created.append(staged)
            } else {
                state.failed.insert(imageURL)
            }
        }
        return staged
    }

    // MARK: Removal

    /// Deletes every staged file. Idempotent; later requests stage again.
    func removeAll() {
        let files = state.withLock { state -> [URL] in
            defer {
                state.files.removeAll()
                state.created.removeAll()
            }
            return state.created
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Staging

    private func stage(_ imageURL: String) -> URL? {
        guard prepareDirectory() else {
            return nil
        }
        let name = UUID().uuidString.lowercased()
        if imageURL.hasPrefix("data:") {
            let item: [String: Any] = ["type": "image_url", "image_url": ["url": imageURL]]
            guard let attachment = RemoteGenerationClient.runtimeImageAttachment(from: item, index: 0),
                  let data = attachment.data,
                  !data.isEmpty else {
                return nil
            }
            let fileExtension = Self.safeExtension(URL(fileURLWithPath: attachment.originalFilename).pathExtension)
            let destination = directory.appendingPathComponent(name + fileExtension, isDirectory: false)
            do {
                try data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }
        guard let source = Self.localFileURL(from: imageURL) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        let destination = directory.appendingPathComponent(
            name + Self.safeExtension(source.pathExtension),
            isDirectory: false
        )
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    /// Creates `directory` (0700) and, the first time the directory is used in
    /// this process, sweeps the files older than `staleFileAge`.
    private func prepareDirectory() -> Bool {
        if state.withLock({ $0.isDirectoryReady }) {
            return true
        }
        do {
            try FileManager.default.createPrivateDirectory(at: directory)
            // The attributes of `createDirectory` may not reach the leaf when
            // intermediates are created: set them explicitly.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        } catch {
            return false
        }
        let shouldSweep = Self.sweptDirectories.withLock { $0.insert(directory.standardizedFileURL.path).inserted }
        if shouldSweep {
            Self.removeStaleFiles(in: directory)
        }
        state.withLock { $0.isDirectoryReady = true }
        return true
    }

    /// Deletes the `<UUID>[.<ext>]` files of `directory` last modified more
    /// than `staleFileAge` ago.
    static func removeStaleFiles(in directory: URL, now: Date = Date(), maximumAge: TimeInterval = staleFileAge) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            guard UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: Helpers

    /// `.ext` for a short alphanumeric extension, otherwise no extension.
    private static func safeExtension(_ fileExtension: String) -> String {
        let lowered = fileExtension.lowercased()
        guard !lowered.isEmpty,
              lowered.count <= maximumExtensionLength,
              lowered.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return ""
        }
        return "." + lowered
    }

    /// The local file an `image_url` refers to: a `file:` URL or an absolute path.
    private static func localFileURL(from imageURL: String) -> URL? {
        if imageURL.hasPrefix("file:") {
            guard let url = URL(string: imageURL), url.isFileURL else {
                return nil
            }
            return url
        }
        guard imageURL.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: imageURL)
    }
}
