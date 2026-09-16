import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Records the bytes replaced by this write and the exact bytes committed by it,
/// not a later filesystem sample. All local text writes share this critical section.
enum LocalOperationWrite {
    private static let lock = NSRecursiveLock()
    @TaskLocal private static var certainty: UInt64?
    @TaskLocal private static var lockDepth = 0

    static func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try $lockDepth.withValue(lockDepth + 1) {
            try $certainty.withValue(OperationMutationUncertainty.snapshot) {
                try operation()
            }
        }
    }

    /// Special-file I/O keeps its original blocking semantics, but must not hold
    /// the process-wide mutation lock. Invalidate this operation and overlapping
    /// writers even when no recorder is installed. Restore every recursive level.
    private static func specialIO<T>(_ operation: () throws -> T) rethrows -> T {
        OperationMutationUncertainty.begin()
        let depth = lockDepth
        for _ in 0..<depth { lock.unlock() }
        defer {
            for _ in 0..<depth { lock.lock() }
            OperationMutationUncertainty.end()
        }
        return try $lockDepth.withValue(0) {
            try $certainty.withValue(nil) { try operation() }
        }
    }

    /// Use the descriptor we checked, not a second path lookup: symlinks and
    /// concurrent replacement cannot swap a FIFO into the regular-file branch.
    static func append(_ data: Data, to path: URL) throws {
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
        var initial = stat()
        let status = stat(path.path, &initial)
        let canProbe = status == 0 ? (initial.st_mode & S_IFMT) == S_IFREG : errno == ENOENT
        let fd = canProbe ? open(path.path, flags | O_NONBLOCK, S_IRUSR | S_IWUSR) : -1
        var info = stat()
        if fd >= 0, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return
        }
        if fd >= 0 { _ = close(fd) }
        try specialIO {
            let descriptor = open(path.path, flags, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        }
    }

    static func patchText(at path: URL) throws -> String {
        var initial = stat()
        let canProbe = stat(path.path, &initial) == 0 && (initial.st_mode & S_IFMT) == S_IFREG
        let fd = canProbe ? open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC) : -1
        var info = stat()
        if fd >= 0, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return text
        }
        if fd >= 0 { _ = close(fd) }
        return try specialIO { try String(contentsOf: path, encoding: .utf8) }
    }

    /// No-follow avoids symlink races; nonblocking prevents a swapped-in FIFO
    /// from hanging open before fstat can reject it. Read only the stat size plus
    /// one sentinel byte and reject growth/shrinkage rather than emit a prefix.
    static func snapshot(_ path: URL) -> Data? {
        guard let recorder = OperationFileChangeRecorder.current else { return nil }
        var initial = stat()
        guard lstat(path.path, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG else { return nil }
        let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev == initial.st_dev, info.st_ino == initial.st_ino,
              info.st_size >= 0, info.st_size <= OperationFileChangeRecorder.maximumTextBytes,
              recorder.reserveSnapshotBytes(Int(info.st_size)) else { return nil }
        let size = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: size + 1)
        var count = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if received < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if received == 0 { break }
            count += received
        }
        var final = stat()
        guard count == size, fstat(fd, &final) == 0, final.st_size == info.st_size else { return nil }
        #if canImport(Darwin)
        guard final.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { return nil }
        #else
        guard final.st_mtim.tv_sec == info.st_mtim.tv_sec,
              final.st_mtim.tv_nsec == info.st_mtim.tv_nsec,
              final.st_ctim.tv_sec == info.st_ctim.tv_sec,
              final.st_ctim.tv_nsec == info.st_ctim.tv_nsec else { return nil }
        #endif
        return Data(bytes.prefix(size))
    }

    static func record(path: URL, existed: Bool, before: Data?, after: String?) {
        guard let recorder = OperationFileChangeRecorder.current else { return }
        guard let certainty, OperationMutationUncertainty.snapshot == certainty else {
            recorder.record(OperationFileChange(path: path.standardizedFileURL.path, oldText: nil, newText: nil,
                explanation: "Diff unavailable: an opaque operation overlapped this file mutation."))
            return
        }
        guard (after?.utf8.count ?? 0) <= OperationFileChangeRecorder.maximumTextBytes else {
            recorder.record(.init(path: path.standardizedFileURL.path, oldText: nil, newText: nil,
                explanation: "Diff unavailable: file evidence exceeds the byte limit."))
            return
        }
        let oldText = before.flatMap { String(data: $0, encoding: .utf8) }
        if after?.contains("\0") != true && oldText?.contains("\0") != true && (!existed || oldText != nil) {
            recorder.record(OperationFileChange(path: path.standardizedFileURL.path, oldText: oldText, newText: after))
        } else {
            recorder.record(OperationFileChange(path: path.standardizedFileURL.path, oldText: nil, newText: nil,
                explanation: "Diff unavailable: contents are nonregular, binary, unreadable, unstable, or exceed the evidence byte limit."))
        }
    }

    static func existsForEvidence(_ path: URL) -> Bool {
        guard OperationFileChangeRecorder.current != nil else { return false }
        var info = stat()
        // A dangling symlink or inaccessible path is not an absent old image.
        return lstat(path.path, &info) == 0 || errno != ENOENT
    }

    static func write(_ text: String, to path: URL) throws {
        try serialized {
            let existed = existsForEvidence(path)
            let before = snapshot(path)
            try text.write(to: path, atomically: true, encoding: .utf8)
            record(path: path, existed: existed, before: before, after: text)
        }
    }
}
