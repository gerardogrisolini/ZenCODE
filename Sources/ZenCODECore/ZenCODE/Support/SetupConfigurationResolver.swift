//
//  SetupConfigurationResolver.swift
//  ZenCODE
//
//  Shared helper for the "configuration file exists but is invalid" branch
//  used across the interactive setup runners. It loads an existing
//  configuration value and, when loading fails, asks the operator whether the
//  file should be overwritten with defaults.
//
import Foundation

public enum SetupConfigurationResolution<Value> {
    /// The existing configuration loaded successfully.
    case loaded(Value)
    /// Loading failed and the operator agreed to overwrite the file.
    case overwrite
}

public enum SetupConfigurationResolver {
    /// Loads an existing configuration value, prompting the operator to rewrite
    /// the file when it exists but cannot be decoded.
    ///
    /// - Parameters:
    ///   - load: Loads and validates the existing configuration value.
    ///   - confirmOverwrite: Asks the operator whether the invalid file should
    ///     be rewritten. Receives the underlying decoding error.
    /// - Returns: `.loaded` when the file is valid, otherwise `.overwrite` once
    ///   the operator agrees to rewrite it.
    /// - Throws: The original decoding error when the operator declines to
    ///   overwrite, or any error thrown by `confirmOverwrite`.
    public static func resolve<Value>(
        load: () throws -> Value,
        confirmOverwrite: (Error) throws -> Bool
    ) throws -> SetupConfigurationResolution<Value> {
        do {
            return .loaded(try load())
        } catch {
            guard try confirmOverwrite(error) else {
                throw error
            }
            return .overwrite
        }
    }
}
