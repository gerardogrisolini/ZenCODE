//
//  ZenCODESetupRunner+BindingPresets.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/10/26.
//
//  Offers binding-presets.json at the end of a first setup. Never automatic.
//

import Foundation

extension ZenCODESetupRunner {
    /// The profiles a first-setup offer would apply the presets to, or `nil`
    /// when no offer must be made. All of these must hold:
    /// - agents.json did not exist when setup began;
    /// - at least one configured provider of `finalManifest` has a block in
    ///   `presets`;
    /// - the profiles setup would write have no binding yet, so work done in the
    ///   same session is never overwritten.
    ///
    /// A presets file that is missing or does not load never reaches this check:
    /// the caller skips the offer silently.
    static func profilesEligibleForBindingPresets(
        presets: AgentBindingPresets,
        agentsFileExisted: Bool,
        finalManifest: AgentSettingsManifest,
        stagedProfiles: [AgentProfile]?
    ) -> [AgentProfile]? {
        guard !agentsFileExisted,
              presets.hasProvider(in: finalManifest.providers.map(\.displayTitle))
        else {
            return nil
        }
        let profiles = stagedProfiles ?? AgentProfileStore.defaultProfiles()
        guard profiles.allSatisfy({ $0.modelBindings.isEmpty }) else {
            return nil
        }
        return profiles
    }

    /// Asks whether to apply the binding presets and, only on an explicit yes,
    /// stages the resulting profiles in `session` so `ensureRequiredFiles`
    /// writes them. The default answer is no and a no changes nothing; a
    /// missing or invalid presets file skips the question silently.
    static func offerBindingPresetsAtFirstSetup(
        session: inout SetupSession,
        finalManifest: AgentSettingsManifest,
        agentsFileExisted: Bool,
        presetsURL: URL = AgentBindingPresets.defaultURL(),
        prompt: (String, Bool, String?) throws -> Bool = {
            try promptYesNo($0, defaultValue: $1, help: $2)
        }
    ) throws {
        guard let presets = try? AgentBindingPresets.load(from: presetsURL),
              let profiles = profilesEligibleForBindingPresets(
                  presets: presets,
                  agentsFileExisted: agentsFileExisted,
                  finalManifest: finalManifest,
                  stagedProfiles: session.agentProfiles
              )
        else {
            return
        }

        guard try prompt(
            "Apply binding presets from \(AgentBindingPresets.filename)?",
            false,
            """
            Assigns model bindings to every agent from \(presetsURL.path), using only \
            the providers you configured. Agents with no entry there get no bindings. \
            You can still change them later in /setup > Agent model bindings.
            """
        ) else {
            return
        }

        let updated = presets.applying(
            to: profiles,
            configuredProviderNames: finalManifest.providers.map(\.displayTitle)
        )
        session.stageAgentProfiles(updated)
        AgentOutput.standardError.writeString(
            "\nBinding presets staged: \(AgentBindingPresets.outcomeDescription(for: updated)).\n"
        )
    }
}
