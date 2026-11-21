//
//  ZenCODESetupRunner+DS4Prompts.swift
//  ZenCODE
//
//  The questions of the DS4 setup flow gathered in one value: each one is a
//  closure that defaults to the real interactive prompt and that tests replace.
//

import Foundation
import ZenCODERuntime

/// What a tuning question needs besides the model and its defaults. The
/// interactive question uses it; the injected seam of tests ignores it.
struct DS4SetupTuningContext {
    /// Backend chosen for the model.
    let backend: AgentDS4RuntimeBackend
    /// Whether the model is a DeepSeek model. DeepSeek uses DSpark, chosen
    /// with its support GGUF, so the built-in MTP of the other families is
    /// not asked.
    let usesDSpark: Bool
}

/// What the operator chose in the "DS4 models" menu.
enum DS4SetupModelMenuChoice: Hashable, Sendable {
    /// Keeps the models as they are now and ends the menu.
    case done
    /// Adds GGUFs of the folder that no model uses yet.
    case add
    /// Asks the questions of the model with this id again.
    case configure(String)
    /// Removes the model with this id.
    case delete(String)
}

/// Every question the DS4 setup asks: the folder, then the "DS4 models" menu
/// when models are already configured, the model files to add, and for each
/// model its backend, the tuning, the optional vision projector and, for a
/// DeepSeek model, the DSpark support model.
///
/// The API model id is asked only when nothing else gives it: neither the
/// catalog, nor the name of the GGUF, nor the model already saved for that
/// GGUF (when it holds a served API id).
///
/// A closure that is not injected asks the user in the terminal.
struct DS4SetupPrompts {
    /// Receives the previously saved DS4 folder; returns the folder (`nil`: none).
    let folder: (String?) throws -> String?
    /// Receives the GGUFs that can be added (the ones no model uses yet) and
    /// the ones to preselect (always empty); returns the chosen relative
    /// paths (`nil`: cancelled).
    let files: ([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?
    /// Receives the configured models and whether the folder holds GGUFs to
    /// add; returns the operator's choice. Esc throws
    /// `ZenCODESetupError.cancelled`.
    let modelMenu: ([AgentSettingsModelManifest], Bool) throws -> DS4SetupModelMenuChoice
    /// Receives the model and the backend to propose (the saved one, else the
    /// default of the platform); returns the backend chosen for the model.
    let backend: (DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend
    /// Asked for each model for the vision projector and, for a DeepSeek
    /// model, for the DSpark support model, unless the folder holds no other
    /// GGUF to pair. See ``DS4SetupAuxiliaryFileSelector`` for what it
    /// receives and returns.
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
        promptFolder: ((String?) throws -> String?)? = nil,
        selectFiles: (([DS4SetupModelCandidate], Set<String>) throws -> Set<String>?)? = nil,
        selectModelMenu: (([AgentSettingsModelManifest], Bool) throws -> DS4SetupModelMenuChoice)? = nil,
        selectBackend: ((DS4SetupModelCandidate, AgentDS4RuntimeBackend) throws -> AgentDS4RuntimeBackend)? = nil,
        selectAPIModelID: ((DS4SetupModelCandidate) throws -> String)? = nil,
        selectAuxiliaryFile: DS4SetupAuxiliaryFileSelector? = nil,
        promptTuning: ((DS4SetupModelCandidate, AgentDS4RuntimeTuning) throws -> AgentDS4RuntimeTuning)? = nil
    ) {
        folder = promptFolder ?? Self.promptFolder
        files = selectFiles ?? Self.promptModelFiles
        modelMenu = selectModelMenu ?? Self.promptModelMenu
        backend = selectBackend ?? Self.promptBackend
        apiModelID = selectAPIModelID ?? Self.promptAPIModelID
        auxiliaryFile = selectAuxiliaryFile ?? Self.promptAuxiliaryFile
        if let promptTuning {
            tuning = { candidate, defaults, _ in try promptTuning(candidate, defaults) }
        } else {
            tuning = Self.promptTuning
        }
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
            title: "Add DS4 models",
            items: items,
            selected: preselected
        )
    }

    /// One row of the "DS4 models" menu.
    private enum ModelMenuEntry: Hashable {
        case done
        case add
        case model(String)
    }

    /// The "DS4 models" menu, then the action menu of the model chosen. Esc on
    /// the action menu goes back to the models menu, whose own Esc throws
    /// `ZenCODESetupError.cancelled`.
    private static func promptModelMenu(
        _ models: [AgentSettingsModelManifest],
        _ canAdd: Bool
    ) throws -> DS4SetupModelMenuChoice {
        while true {
            var items: [TerminalCheckboxMenuItem<ModelMenuEntry>] = [
                TerminalCheckboxMenuItem(
                    value: .done,
                    title: "Done",
                    detail: "keep these DS4 models"
                )
            ]
            if canAdd {
                items.append(
                    TerminalCheckboxMenuItem(
                        value: .add,
                        title: "Add models",
                        detail: "configure GGUF files of the DS4 folder that no model uses yet",
                        groupTitle: "Actions"
                    )
                )
            }
            items.append(contentsOf: models.map { model in
                TerminalCheckboxMenuItem(
                    value: .model(model.id),
                    title: model.displayTitle,
                    detail: ZenCODESetupRunner.ds4ModelSummary(model),
                    groupTitle: "Models"
                )
            })

            let entry = try ZenCODESetupRunner.promptMenuChoice(
                title: "DS4 models",
                items: items,
                selected: .done
            )
            switch entry {
            case .done:
                return .done
            case .add:
                return .add
            case let .model(id):
                guard let model = models.first(where: { $0.id == id }) else {
                    continue
                }
                let action = TerminalCheckboxMenu.selectOne(
                    title: model.displayTitle,
                    items: [
                        TerminalCheckboxMenuItem(
                            value: DS4SetupModelMenuChoice.configure(id),
                            title: "Configure",
                            detail: "backend, context, SSD streaming, MTP or DSpark, vision"
                        ),
                        TerminalCheckboxMenuItem(
                            value: DS4SetupModelMenuChoice.delete(id),
                            title: "Delete",
                            detail: "remove this model from DS4"
                        )
                    ],
                    selected: .configure(id)
                )
                if let action {
                    return action
                }
            }
        }
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
        let none: TerminalCheckboxMenuItem<String?>
        let title: String
        switch kind {
        case .vision:
            none = TerminalCheckboxMenuItem(value: nil, title: "None", detail: nil)
            title = "Optional \(kind.title) for \(model.title)"
        case .dspark:
            none = TerminalCheckboxMenuItem(value: nil, title: "Off", detail: "no DSpark")
            title = "DSpark for \(model.title): choose its support model to enable it"
        }
        let files = pairable.map {
            TerminalCheckboxMenuItem<String?>(value: $0.relativePath, title: $0.title, detail: $0.relativePath)
        }
        return try ZenCODESetupRunner.promptMenuChoice(
            title: title,
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
            usesDSpark: context.usesDSpark
        )
    }
}
