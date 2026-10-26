//
//  DS4EngineABI.swift
//  ZenCODE
//
//  Shared constants of the ZenCODE-owned DS4 engine shim ABI declared in
//  `Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h`. The dynamic
//  library is built on the user's machine and loaded at runtime, so these
//  values are the only compile-time contract between `zen` and the shim.
//

import Foundation

enum DS4EngineABI {
    /// Must equal `ZENCODE_DS4_ABI_VERSION` in `zencode_ds4_abi.h`. A library
    /// reporting a different value is treated as stale and must be rebuilt.
    /// Version 2 added `zencode_ds4_tokens_push` (exact token replay).
    static let expectedVersion: Int32 = 2

    /// Base name of the dynamic library produced by `Scripts/build-ds4-engine.sh`.
    static let libraryBaseName = "libzencode-ds4"

    /// Platform file name of the dynamic library.
    static var libraryFileName: String {
        #if os(macOS)
        "\(libraryBaseName).dylib"
        #else
        "\(libraryBaseName).so"
        #endif
    }
}
