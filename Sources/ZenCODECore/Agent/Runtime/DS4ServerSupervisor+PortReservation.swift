//
//  DS4ServerSupervisor+PortReservation.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A short-lived loopback listener used only to choose/reserve a port before a
/// child launch. It never owns or terminates a process.
final class DS4PortReservation: @unchecked Sendable {
    let port: Int
    private var fileDescriptor: Int32?

    private init(fileDescriptor: Int32, port: Int) {
        self.fileDescriptor = fileDescriptor
        self.port = port
    }

    static func bind(host: String, requestedPort: Int?) throws -> DS4PortReservation {
        #if os(macOS) || os(Linux)
        let port = UInt16(requestedPort ?? 0).bigEndian
        if host.lowercased() == "::1" {
            var address = sockaddr_in6()
            #if os(macOS)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port
            var loopbackAddress = in6_addr()
            withUnsafeMutableBytes(of: &loopbackAddress) { $0[15] = 1 }
            address.sin6_addr = loopbackAddress
            return try reserve(family: AF_INET6, address: &address) { $0.sin6_port }
        }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return try reserve(family: AF_INET, address: &address) { $0.sin_port }
        #else
        _ = host
        _ = requestedPort
        throw POSIXPortError.unsupported
        #endif
    }

    #if os(macOS) || os(Linux)
    /// Binds and listens on `address`, then reads back the assigned port.
    private static func reserve<Address>(
        family: Int32,
        address: inout Address,
        assignedPort: (Address) -> UInt16
    ) throws -> DS4PortReservation {
        #if os(Linux)
        let fileDescriptor = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fileDescriptor = socket(family, SOCK_STREAM, 0)
        #endif
        guard fileDescriptor >= 0 else { throw POSIXPortError.bindFailed }
        var length = socklen_t(MemoryLayout<Address>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.bind(fileDescriptor, $0, length)
            }
        }
        guard bound == 0, DarwinOrGlibc.listen(fileDescriptor, 1) == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.getsockname(fileDescriptor, $0, &length)
            }
        }
        let port = Int(UInt16(bigEndian: assignedPort(address)))
        guard named == 0, port > 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        return DS4PortReservation(fileDescriptor: fileDescriptor, port: port)
    }
    #endif

    func release() {
        guard let fileDescriptor else { return }
        self.fileDescriptor = nil
        DarwinOrGlibc.close(fileDescriptor)
    }

    deinit { release() }
}

enum POSIXPortError: Error {
    case bindFailed
    case unsupported
}

#if os(macOS)
enum DarwinOrGlibc {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.bind(fd, address, length)
    }
    static func getsockname(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Darwin.getsockname(fd, address, length)
    }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func close(_ fd: Int32) { _ = Darwin.close(fd) }
}
#elseif os(Linux)
enum DarwinOrGlibc {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.bind(fd, address, length)
    }
    static func getsockname(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Glibc.getsockname(fd, address, length)
    }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func close(_ fd: Int32) { _ = Glibc.close(fd) }
}
#else
enum DarwinOrGlibc {
    static func close(_ fd: Int32) { _ = fd }
}
#endif
