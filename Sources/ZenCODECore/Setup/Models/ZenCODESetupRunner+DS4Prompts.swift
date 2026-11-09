//
//  ZenCODESetupRunner+DS4Prompts.swift
//  ZenCODE
//
//  The questions of the DS4 setup flow gathered in one value: each one is a
//  closure that defaults to the real interactive prompt and that tests replace.
//

import Foundation

/// What a tuning question needs besides the model and its defaults. The
/// interactive question uses it; the injected seam of tests ignores it.
struct DS4SetupTuningContext {
    /// Backend chosen for the model.
    let backend: AgentDS4RuntimeBackend
    /// Canonical DS4 folder.
    let rootDirectory: String
    /// Whether an MTP / DSpark support model is paired with the model.
    let hasMTPModel: Bool
}

/// Every question the DS4 setup asks, in the order the flow asks them: the
/// folder, the model files, then for each model its backend, the optional
/// vision and MTP / DSpark files, the tuning and last the API model id.
///
/// The API model id is asked only when nothing else gives it: neither the
/// catalog, nor the name of the GGUF, nor the model already saved for that
/// GGUF (when it holds a served API id).
///
/// A closure that is not injected asks the user in the terminal.
struct DS4SetupPrompts {
    /// Receives the previously saved DS4 folder; returns the folder (`nil`: none).
    let folder: (String?) throws -> String?
    /// Receives the candidates and the already saved ones; returns the chosen
    /// relative paths (`nil`: cancelled).
    let files: ([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?
    /// Receives the model and the backend to propose (the saved one, else the
    /// default of the platform); returns the backend chosen for the model.
    let backend: (DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend
    /// Asked for each model once per ``DS4SetupAuxiliaryKind`` (vision, then
    /// MTP / DSpark), unless the folder holds no other GGUF to pair. See
    /// ``DS4SetupAuxiliaryFileSelector`` for what it receives and returns.
    let auxiliaryFile: DS4SetupAuxiliaryFileSelector
    /// Receives the model, the tuning to propose (from the runtime saved for
    /// that model) and the context of the flow; returns the tuning chosen.
    let tuning: (
        DS4SetupModelCandidate,
        AgentDS4RuntimeTuning,
        DS4SetupTuningContext
    ) throws -> AgentDS4RuntimeTuning
    /// Receives the model; returns one of the served API model ids.
    let apiModelID: (DS4SetupModelCandidate) throws -> String

    /// Builds the questions from the seams a caller injects; the ones left
    /// `nil` use the interactive prompt. The injected tuning seam takes no
    /// context: it is dropped, and the seam receives the model and its defaults.
    init(
        folder: ((String?) throws -> String?)? = nil,
        files: (([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?)? = nil,
        backend: ((DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend)? = nil,
        auxiliaryFile: DS4SetupAuxiliaryFileSelector? = nil,
        tuning: ((DS4SetupModelCandidate, AgentDS4RuntimeTuning) throws -> AgentDS4RuntimeTuning)? = nil,
        apiModelID: ((DS4SetupModelCandidate) throws -> String)? = nil
    ) {
        self.folder = folder ?? Self.promptFolder
        self.files = files ?? Self.promptModelFiles
        self.backend = backend ?? Self.promptBackend
        self.auxiliaryFile = auxiliaryFile ?? Self.promptAuxiliaryFile
        if let tuning {
            self.tuning = { candidate, defaults, _ in try tuning(candidate, defaults) }
        } else {
            self.tuning = Self.promptTuning
        }
        self.apiModelID = apiModelID ?? Self.promptAPIModelID
    }

    // MARK: Interactive prompts

    private static func promptFolder(_ previousRootDirectory: String?) throws -> String? {
        try ZenCODESetupRunner.promptString(
            "DS4 folder",
            defaultValue: previousRootDirectory,
            allowEmpty: false,
            help: "Enter your DS4 checkout (it holds ds4.h and the GGUF models). Setup scans it for GGUF files and can build ZenCODE's in-process engine library against it; it never downloads DS4 or changes the checkout."
        )
    }

    private static func promptModelFiles(
        _ candidates: [DS4SetupModelCandidate],
        _ preselected: Set<String>
    ) -> Set<String>? {
        let items = candidates.map { candidate in
            TerminalCheckboxMenuItem(
                value: candidate.relativePath,
                title: candidate.title,
                detail: candidate.relativePath
            )
        }
        return TerminalCheckboxMenu.select(
            title: "Select DS4 models",
            items: items,
            selected: preselected
        )
    }

    private static func promptBackend(
        _ candidate: DS4SetupModelCandidate,
        _ defaultBackend: AgentDS4RuntimeBackend
    ) throws -> AgentDS4RuntimeBackend {
        try ZenCODESetupRunner.promptMenuChoice(
            title: "DS4 backend for \(candidate.title)",
            items: AgentDS4RuntimeBackend.allCases.map {
                TerminalCheckboxMenuItem(value: $0, title: $0.rawValue, detail: nil)
            },
            selected: defaultBackend
        )
    }

    private static func promptAPIModelID(_ candidate: DS4SetupModelCandidate) throws -> String {
        try ZenCODESetupRunner.promptMenuChoice(
            title: "DS4 API model id for \(candidate.fileName)",
            items: DS4ModelCatalog.servedAPIModelIDs.map {
                TerminalCheckboxMenuItem(value: $0, title: $0, detail: nil)
            },
            selected: DS4ModelCatalog.servedAPIModelIDs[0]
        )
    }

    private static func promptAuxiliaryFile(
        _ model: DS4SetupModelCandidate,
        _ kind: DS4SetupAuxiliaryKind,
        _ pairable: [DS4SetupModelCandidate],
        _ current: String?
    ) throws -> String? {
        let none = TerminalCheckboxMenuItem<String?>(value: nil, title: "None", detail: nil)
        let files = pairable.map {
            TerminalCheckboxMenuItem<String?>(value: $0.relativePath, title: $0.title, detail: $0.relativePath)
        }
        return try ZenCODESetupRunner.promptMenuChoice(
            title: "Optional \(kind.title) for \(model.title)",
            items: [none] + files,
            selected: current
        )
    }

    private static func promptTuning(
        _ candidate: DS4SetupModelCandidate,
        _ defaults: AgentDS4RuntimeTuning,
        _ context: DS4SetupTuningContext
    ) throws -> AgentDS4RuntimeTuning {
        try ZenCODESetupRunner.promptDS4RuntimeTuning(
            modelTitle: candidate.title,
            defaults: defaults,
            backend: context.backend,
            rootDirectory: context.rootDirectory,
            hasMTPModel: context.hasMTPModel
        )
    }
}
