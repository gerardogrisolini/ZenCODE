//
//  DS4EngineConfiguration+Mock.swift
//  ZenCODE
//
//  Test configuration for the mock DS4 engines.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension DS4EngineConfiguration {
    /// Configuration for tests (the library is never loaded by the mocks).
    static func mock(
        model: String = "/tmp/zencode-ds4-tests/model.gguf",
        contextSize: Int = 4096,
        sessionCapacity: Int = 2,
        extraOptions: [DS4EngineOption] = []
    ) -> DS4EngineConfiguration {
        DS4EngineConfiguration(
            libraryURL: URL(fileURLWithPath: "/tmp/zencode-ds4-tests/\(DS4EngineABI.libraryFileName)"),
            options: [DS4EngineOption(key: "model_path", value: model)] + extraOptions,
            contextSize: contextSize,
            sessionCapacity: sessionCapacity,
            buildHint: "Scripts/build-ds4-engine.sh --ds4-root /tmp/ds4"
        )
    }
}
