//
//  DS4EngineLibraryVerifier.swift
//  ZenCODE
//
//  Post-build check of a freshly built engine library: it must load with
//  dlopen() and report the ABI version this build of ZenCODE was written for.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Seam for the post-build library check, so builder tests need no real library.
protocol DS4EngineLibraryVerifying: Sendable {
    /// Loads the library and returns the value of `zencode_ds4_abi_version()`.
    func abiVersion(ofLibraryAt url: URL) throws -> Int32
}

/// Loads the library with `dlopen(RTLD_NOW | RTLD_LOCAL)`, calls
/// `zencode_ds4_abi_version` and closes the handle again. No model is loaded.
struct DS4EngineDynamicLibraryVerifier: DS4EngineLibraryVerifying {
    private typealias ABIVersionFunction = @convention(c) () -> Int32

    func abiVersion(ofLibraryAt url: URL) throws -> Int32 {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw DS4EngineBuildError.libraryLoadFailed(path: url.path, reason: reason)
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "zencode_ds4_abi_version") else {
            throw DS4EngineBuildError.abiSymbolMissing(path: url.path)
        }
        let function = unsafeBitCast(symbol, to: ABIVersionFunction.self)
        return function()
    }
}
