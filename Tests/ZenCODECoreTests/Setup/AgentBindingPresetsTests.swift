//
//  AgentBindingPresetsTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentBindingPresetsTests {
    // MARK: - Fixtures

    private static let documentedFile = #"""
    {
      "version": 1,
      "providers": {
        "Claude Subscription": {
          "developer": {
            "defaultModelBindingID": "claude:claude-opus-5-5",
            "modelBindings": [
              { "id": "claude:claude-haiku-5-5", "modelID": "claude:claude-haiku-5-5", "modelProvider": "Claude Subscription", "capability": 2, "thinkingSelection": "low" },
              { "id": "claude:claude-opus-5-5", "modelID": "claude:claude-opus-5-5", "modelProvider": "Claude Subscription", "capability": 8, "thinkingSelection": "high" }
            ]
          },
          "reviewer": { "modelBindings": [] }
        },
        "OpenRouter": { "developer": { "modelBindings": [] } }
      }
    }
    """#

    private static func presets(_ json: String) throws -> AgentBindingPresets {
        try AgentBindingPresets(data: Data(json.utf8))
    }

    private static func binding(_ id: String, capability: Int = 5) -> AgentModelBinding {
        AgentModelBinding(id: id, modelID: id, modelProvider: "Test", capability: capability)
    }

    /// A presets document with one developer-role block per provider, written
    /// in the given order. Each provider lists one binding named after itself
    /// and optionally declares a default.
    private static func document(
        providers: [(name: String, bindingID: String, defaultID: String?)],
        entry: String = "developer"
    ) -> String {
        let blocks = providers.map { provider -> String in
            let defaultLine = provider.defaultID.map {
                #""defaultModelBindingID": "\#($0)", "#
            } ?? ""
            return """
            "\(provider.name)": { "\(entry)": { \(defaultLine)"modelBindings": [
              { "id": "\(provider.bindingID)", "modelID": "\(provider.bindingID)", "capability": 5 }
            ] } }
            """
        }
        return #"{ "version": 1, "providers": { "# + blocks.joined(separator: ", ") + " } }"
    }

    private static func profile(
        id: String,
        role: AgentProfileRole = .developer,
        name: String = "Agent",
        bindings: [AgentModelBinding] = [],
        defaultBindingID: String? = nil
    ) -> AgentProfile {
        AgentProfile(
            id: id,
            name: name,
            instructions: "Keep these instructions.",
            symbolName: "hammer",
            readOnly: true,
            role: role,
            tools: ["files", "text"],
            skills: [AgentProfileSkill(id: "swift-review", canonicalName: "swift-review")],
            modelBindings: bindings,
            defaultModelBindingID: defaultBindingID
        )
    }

    private static func providerManifest(_ name: String) -> AgentSettingsProviderManifest {
        AgentSettingsProviderManifest(
            id: UUID(),
            name: name,
            baseURL: "https://\(UUID().uuidString.lowercased()).example.invalid/v1",
            chatEndpoint: .chatCompletions
        )
    }

    private static func manifest(providers names: [String]) -> AgentSettingsManifest {
        AgentSettingsManifest(
            providers: names.map(providerManifest),
            models: []
        )
    }

    /// A manifest with one remote model, so a setup session built on it has a
    /// writable outcome.
    private static func manifestWithModel(providerName: String) -> AgentSettingsManifest {
        let providerID = UUID()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: "https://example.invalid/v1",
            modelID: "test-model"
        )
        let model = AgentSettingsModelManifest(
            id: "remote:test-model",
            kind: .remoteAPI,
            modelID: "test-model",
            providerID: providerID,
            provider: provider
        )
        return AgentSettingsManifest(models: [model])
    }

    private static func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "zencode-binding-presets-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    // MARK: - Format

    @Test
    func decodesTheDocumentedFormat() throws {
        let presets = try Self.presets(Self.documentedFile)

        #expect(presets.providers.map(\.name) == ["Claude Subscription", "OpenRouter"])

        let claude = try #require(presets.providers.first)
        let developer = try #require(claude.blocksByProfileKey["developer"])
        #expect(developer.defaultModelBindingID == "claude:claude-opus-5-5")
        #expect(developer.modelBindings.map(\.id) == [
            "claude:claude-haiku-5-5",
            "claude:claude-opus-5-5"
        ])
        let haiku = try #require(developer.modelBindings.first)
        #expect(haiku.modelID == "claude:claude-haiku-5-5")
        #expect(haiku.modelProvider == "Claude Subscription")
        #expect(haiku.capability == 2)
        #expect(haiku.thinkingSelection == .low)
        #expect(developer.modelBindings.last?.thinkingSelection == .high)

        let reviewer = try #require(claude.blocksByProfileKey["reviewer"])
        #expect(reviewer.modelBindings.isEmpty)
        #expect(reviewer.defaultModelBindingID == nil)

        #expect(presets.providers.last?.blocksByProfileKey["developer"]?.modelBindings.isEmpty == true)
    }

    @Test
    func providerOrderIsTheFileOrderNotAlphabetical() throws {
        let presets = try Self.presets(
            Self.document(providers: [
                (name: "Zeta", bindingID: "z", defaultID: nil),
                (name: "Alpha", bindingID: "a", defaultID: nil),
                (name: "Mid", bindingID: "m", defaultID: nil)
            ])
        )

        #expect(presets.providers.map(\.name) == ["Zeta", "Alpha", "Mid"])
    }

    @Test
    func emptyAndFoldedBlockKeysAreNormalizedOrDropped() throws {
        let presets = try Self.presets(#"""
        { "version": 1, "providers": { "P": {
          "": { "modelBindings": [ { "id": "empty", "modelID": "empty" } ] },
          "   ": { "modelBindings": [ { "id": "blank", "modelID": "blank" } ] },
          " Developer ": { "modelBindings": [ { "id": "dev", "modelID": "dev" } ] }
        } } }
        """#)

        let blocks = try #require(presets.providers.first).blocksByProfileKey
        #expect(Set(blocks.keys) == ["developer"])
        #expect(blocks["developer"]?.modelBindings.map(\.id) == ["dev"])
    }

    // MARK: - Key order scanner

    @Test
    func scannerReturnsKeysInFileOrderWithEscapesNestingAndWhitespace() throws {
        let json = #"""
        {
          "meta" : { "providers" : { "decoy" : 1 } , "list":[1, 2.5e3, true, null, "x\"}", {"providers":{}}] },
          "version" : 1 ,
        	"providers" :
          {
             "Zeta"  :  { "a" : [ { "b" : "}{ ] [ \" , " } ] , "c" : null } ,
             "Al\"pha\\" : 3,
             "caf\u00e9": -1.5E+2,
             "\ud83d\ude00 smile":{},
             "mid"  :[],
             "tab\tkey" : "v"
          },
          "tail": { "providers": { "after": 1 } }
        }
        """#
        let data = Data(json.utf8)
        // The fixture is real JSON, so the scanner is exercised on valid input.
        _ = try JSONSerialization.jsonObject(with: data)

        #expect(
            AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: data) == [
                "Zeta",
                "Al\"pha\\",
                "café",
                "\u{1F600} smile",
                "mid",
                "tab\tkey"
            ]
        )
    }

    @Test
    func scannerCountsADuplicateKeyAtItsFirstOccurrence() {
        let data = Data(#"""
        { "providers": { "B": 1, "A": 2, "B": 3, "C": {"x": 1}, "A": 4 } }
        """#.utf8)

        #expect(
            AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: data) == ["B", "A", "C"]
        )
    }

    @Test
    func scannerSkipsALeadingByteOrderMarkAndReadsEmptyObjects() {
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"providers":{"x":1}}"#.utf8)
        let empty = Data(#"{ "providers" : { } }"#.utf8)

        #expect(AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: withBOM) == ["x"])
        #expect(AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: empty) == [])
    }

    @Test
    func scannerReturnsNilWhenThereIsNothingToRead() {
        let inputs = [
            "",
            "[]",
            "{}",
            #"{"version":1}"#,
            #"{"providers":[1,2]}"#,
            #"{"providers":"text"}"#,
            #"{"providers":{"a":1"#,
            #"{"providers":{"a" 1}}"#,
            #"{"providers":{"a":}}"#,
            #"{"providers":{"unterminated:1}}"#
        ]

        for input in inputs {
            #expect(
                AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: Data(input.utf8)) == nil,
                "input: \(input)"
            )
        }
    }

    @Test
    func scannerStopsAtExcessiveNesting() {
        let depth = 2_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let data = Data(#"{"meta":"#.utf8) + Data(nested.utf8) + Data(#","providers":{"a":1}}"#.utf8)

        #expect(AgentBindingPresetsKeyScanner.keys(ofMember: "providers", in: data) == nil)
    }

    // MARK: - Application

    @Test
    func onlyConfiguredProvidersApplyAndNamesAreComparedByReferenceKey() throws {
        let presets = try Self.presets(#"""
        { "version": 1, "providers": {
          "Claude Subscription": { "developer": { "modelBindings": [ { "id": "claude", "modelID": "claude" } ] } },
          "OpenRouter": { "developer": { "modelBindings": [ { "id": "router", "modelID": "router" } ] } },
          "": { "developer": { "modelBindings": [ { "id": "empty", "modelID": "empty" } ] } },
          "   ": { "developer": { "modelBindings": [ { "id": "blank", "modelID": "blank" } ] } }
        } }
        """#)
        let profiles = [Self.profile(id: "developer")]

        let claudeOnly = presets.applying(
            to: profiles,
            configuredProviderNames: [" claude SUBSCRIPTION ", "Unrelated", "", "  "]
        )
        #expect(claudeOnly[0].modelBindings.map(\.id) == ["claude"])

        let none = presets.applying(
            to: profiles,
            configuredProviderNames: ["Unrelated", "", "  "]
        )
        #expect(none[0].modelBindings.isEmpty)
        #expect(none[0].defaultModelBindingID == nil)
    }

    @Test
    func hasProviderRequiresAConfiguredProviderWithABlock() throws {
        let presets = try Self.presets(Self.documentedFile)

        #expect(presets.hasProvider(in: ["claude subscription"]))
        #expect(presets.hasProvider(in: ["Other", "OpenRouter"]))
        #expect(!presets.hasProvider(in: ["Other", ""]))
        #expect(!presets.hasProvider(in: []))
    }

    @Test
    func bindingsAreConcatenatedAcrossConfiguredProviders() throws {
        let presets = try Self.presets(
            Self.document(providers: [
                (name: "Second", bindingID: "b-second", defaultID: nil),
                (name: "First", bindingID: "a-first", defaultID: nil),
                (name: "Skipped", bindingID: "c-skipped", defaultID: nil)
            ])
        )

        let applied = presets.applying(
            to: [Self.profile(id: "developer")],
            configuredProviderNames: ["First", "Second"]
        )

        #expect(Set(applied[0].modelBindings.map(\.id)) == ["a-first", "b-second"])
        #expect(applied[0].modelBindings.count == 2)
    }

    @Test
    func defaultComesFromTheFirstProviderInFileOrderEvenWhenSettingsOrderDiffers() throws {
        let presets = try Self.presets(
            Self.document(providers: [
                (name: "Zeta", bindingID: "z-binding", defaultID: "z-binding"),
                (name: "Alpha", bindingID: "a-binding", defaultID: "a-binding")
            ])
        )
        let profiles = [Self.profile(id: "developer")]

        // settings.json lists providers alphabetically: Alpha first. The file
        // order, not that order, decides the default.
        let applied = presets.applying(
            to: profiles,
            configuredProviderNames: ["Alpha", "Zeta"]
        )
        #expect(Set(applied[0].modelBindings.map(\.id)) == ["a-binding", "z-binding"])
        #expect(applied[0].defaultModelBindingID == "z-binding")

        // A provider that is not configured never contributes a default.
        let alphaOnly = presets.applying(to: profiles, configuredProviderNames: ["Alpha"])
        #expect(alphaOnly[0].defaultModelBindingID == "a-binding")
    }

    @Test
    func defaultSkipsProvidersThatDeclareNoneOrABlankOne() throws {
        let presets = try Self.presets(
            Self.document(providers: [
                (name: "NoDefault", bindingID: "a-none", defaultID: nil),
                (name: "Blank", bindingID: "b-blank", defaultID: "   "),
                (name: "Declared", bindingID: "c-declared", defaultID: "c-declared")
            ])
        )

        let applied = presets.applying(
            to: [Self.profile(id: "developer")],
            configuredProviderNames: ["NoDefault", "Blank", "Declared"]
        )

        #expect(applied[0].defaultModelBindingID == "c-declared")
    }

    @Test
    func profileIdTakesPrecedenceOverRoleInEachProviderBlock() throws {
        let presets = try Self.presets(#"""
        { "version": 1, "providers": {
          "A": {
            "developer": { "modelBindings": [ { "id": "a-role", "modelID": "a-role" } ] },
            "custom-dev": { "modelBindings": [ { "id": "a-id", "modelID": "a-id" } ] }
          },
          "B": {
            "developer": { "modelBindings": [ { "id": "b-role", "modelID": "b-role" } ] }
          }
        } }
        """#)
        let custom = Self.profile(id: "Custom-Dev", role: .developer)

        let applied = presets.applying(
            to: [custom],
            configuredProviderNames: ["A", "B"]
        )

        // A has an entry for the id, so its role entry is ignored; B has only
        // the role entry, which applies.
        #expect(applied[0].modelBindings.map(\.id) == ["a-id", "b-role"])
    }

    @Test
    func customProfileFallsBackToItsRole() throws {
        let presets = try Self.presets(#"""
        { "version": 1, "providers": {
          "A": {
            "reviewer": { "defaultModelBindingID": "role-binding", "modelBindings": [ { "id": "role-binding", "modelID": "role-binding" } ] }
          }
        } }
        """#)
        let customReviewer = Self.profile(id: "security-review", role: .reviewer)
        let customDeveloper = Self.profile(id: "other", role: .developer)

        let applied = presets.applying(
            to: [customReviewer, customDeveloper],
            configuredProviderNames: ["A"]
        )

        #expect(applied[0].modelBindings.map(\.id) == ["role-binding"])
        #expect(applied[0].defaultModelBindingID == "role-binding")
        #expect(applied[1].modelBindings.isEmpty)
    }

    @Test
    func profilesWithoutAnEntryAreEmptiedAndOtherFieldsArePreserved() throws {
        let presets = try Self.presets(#"""
        { "version": 1, "providers": {
          "A": { "developer": { "modelBindings": [ { "id": "dev", "modelID": "dev", "capability": 7 } ] } }
        } }
        """#)
        let developer = Self.profile(id: "developer")
        let previous = Self.profile(
            id: "builder",
            role: .builder,
            name: "Builder",
            bindings: [Self.binding("old-1"), Self.binding("old-2")],
            defaultBindingID: "old-2"
        )

        let applied = presets.applying(
            to: [developer, previous],
            configuredProviderNames: ["A"]
        )

        #expect(applied[0].modelBindings.map(\.id) == ["dev"])
        #expect(applied[0].modelBindings.first?.capability == 7)

        #expect(applied[1].modelBindings.isEmpty)
        #expect(applied[1].defaultModelBindingID == nil)

        for (original, result) in zip([developer, previous], applied) {
            #expect(result.id == original.id)
            #expect(result.name == original.name)
            #expect(result.instructions == original.instructions)
            #expect(result.symbolName == original.symbolName)
            #expect(result.readOnly == original.readOnly)
            #expect(result.role == original.role)
            #expect(result.tools == original.tools)
            #expect(result.skills == original.skills)
        }
    }

    // MARK: - Loading

    @Test
    func loadReturnsNilForAMissingFile() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)

            let presets = try AgentBindingPresets.load(from: url)

            #expect(presets == nil)
        }
    }

    @Test
    func loadReadsTheFileInFileOrder() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(
                Self.document(providers: [
                    (name: "OpenRouter", bindingID: "or", defaultID: nil),
                    (name: "Claude Subscription", bindingID: "cl", defaultID: nil)
                ]).utf8
            ).write(to: url)

            let presets = try #require(try AgentBindingPresets.load(from: url))

            #expect(presets.providers.map(\.name) == ["OpenRouter", "Claude Subscription"])
        }
    }

    @Test
    func loadRejectsInvalidJSONNamingTheFile() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data("{ not json".utf8).write(to: url)

            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: url)
            }
            guard case let .invalidFile(errorURL, _)? = error else {
                Issue.record("Expected invalidFile, got \(String(describing: error))")
                return
            }
            #expect(errorURL == url)
            #expect(error?.localizedDescription.contains(url.path) == true)
        }
    }

    @Test
    func loadRejectsAStructurallyInvalidFileAndSaysWhere() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(#"""
            { "version": 1, "providers": { "A": { "developer": { "modelBindings": "nope" } } } }
            """#.utf8).write(to: url)

            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: url)
            }
            guard case .invalidFile? = error else {
                Issue.record("Expected invalidFile, got \(String(describing: error))")
                return
            }
            let message = error?.localizedDescription ?? ""
            #expect(message.contains(url.path))
            #expect(message.contains("modelBindings"))
        }
    }

    @Test
    func loadRejectsAFileWithoutProviders() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(#"{ "version": 1 }"#.utf8).write(to: url)

            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: url)
            }
            guard case .invalidFile? = error else {
                Issue.record("Expected invalidFile, got \(String(describing: error))")
                return
            }
        }
    }

    @Test
    func loadRejectsAnUnsupportedVersion() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            // The providers shape is not the version-1 one: the version wins.
            try Data(#"{ "version": 2, "providers": [] }"#.utf8).write(to: url)

            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: url)
            }
            guard case let .unsupportedVersion(errorURL, found, expected)? = error else {
                Issue.record("Expected unsupportedVersion, got \(String(describing: error))")
                return
            }
            #expect(errorURL == url)
            #expect(found == 2)
            #expect(expected == AgentBindingPresets.currentVersion)
            #expect(error?.localizedDescription.contains(url.path) == true)
            #expect(error?.localizedDescription.contains("version 2") == true)
        }
    }

    @Test
    func loadRejectsAMissingVersion() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(#"{ "providers": {} }"#.utf8).write(to: url)

            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: url)
            }
            guard case .invalidFile? = error else {
                Issue.record("Expected invalidFile, got \(String(describing: error))")
                return
            }
        }
    }

    @Test
    func loadReportsAnUnreadablePath() throws {
        try Self.withTemporaryDirectory { directory in
            // A directory exists but cannot be read as a file.
            let error = #expect(throws: AgentBindingPresetsError.self) {
                try AgentBindingPresets.load(from: directory)
            }
            guard case .unreadableFile? = error else {
                Issue.record("Expected unreadableFile, got \(String(describing: error))")
                return
            }
        }
    }

    @Test
    func defaultURLSitsNextToSettingsInTheSupportDirectory() throws {
        try Self.withTemporaryDirectory { directory in
            AppStorageDirectory.withSupportDirectoryURL(directory) {
                let url = AgentBindingPresets.defaultURL()

                #expect(url.lastPathComponent == "binding-presets.json")
                #expect(
                    url.deletingLastPathComponent()
                        == AgentSettingsManifestStore.settingsURL().deletingLastPathComponent()
                )
                #expect(
                    url.deletingLastPathComponent().standardizedFileURL
                        == directory.standardizedFileURL
                )
                #expect(
                    url.deletingLastPathComponent()
                        == AgentProfileStore.agentsManifestURL().deletingLastPathComponent()
                )
            }
        }
    }

    // MARK: - Setup session staging

    @Test
    func stagingProfilesLeavesTheSettingsBookkeepingUntouched() {
        let configured = Self.manifestWithModel(providerName: "Claude Subscription")
        var session = SetupSession(originalManifest: configured)
        let staged = [Self.profile(id: "developer", bindings: [Self.binding("dev")])]

        session.stageAgentProfiles(staged)

        #expect(session.agentProfiles == staged)
        #expect(session.manifest == configured)
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .write(manifest: configured, settingsWillBeWritten: false))

        // Quick setup after staging still replaces the staged profiles.
        let replacement = [Self.profile(id: "developer")]
        session.applyQuickSetup(configured, agentProfiles: replacement)
        #expect(session.agentProfiles == replacement)
    }

    // MARK: - First setup offer

    private static let firstSetupFile = Self.document(providers: [
        (name: "Claude Subscription", bindingID: "claude-binding", defaultID: "claude-binding")
    ])

    @Test
    func firstSetupOfferRequiresEveryCondition() throws {
        let presets = try Self.presets(Self.firstSetupFile)
        let configured = Self.manifest(providers: ["Claude Subscription", "Other"])
        let unrelated = Self.manifest(providers: ["Other"])
        let bound = [Self.profile(id: "developer", bindings: [Self.binding("dev")])]
        let unbound = [Self.profile(id: "developer")]

        // Every condition holds: the defaults are the profiles to apply to.
        let defaults = ZenCODESetupRunner.profilesEligibleForBindingPresets(
            presets: presets,
            agentsFileExisted: false,
            finalManifest: configured,
            stagedProfiles: nil
        )
        #expect(defaults?.map(\.id) == AgentProfileStore.defaultProfiles().map(\.id))

        // Staged profiles without bindings are the ones used.
        #expect(
            ZenCODESetupRunner.profilesEligibleForBindingPresets(
                presets: presets,
                agentsFileExisted: false,
                finalManifest: configured,
                stagedProfiles: unbound
            ) == unbound
        )

        // agents.json already existed.
        #expect(
            ZenCODESetupRunner.profilesEligibleForBindingPresets(
                presets: presets,
                agentsFileExisted: true,
                finalManifest: configured,
                stagedProfiles: nil
            ) == nil
        )

        // No configured provider has a block in the file.
        #expect(
            ZenCODESetupRunner.profilesEligibleForBindingPresets(
                presets: presets,
                agentsFileExisted: false,
                finalManifest: unrelated,
                stagedProfiles: nil
            ) == nil
        )

        // Work already done in the same session is never overwritten.
        #expect(
            ZenCODESetupRunner.profilesEligibleForBindingPresets(
                presets: presets,
                agentsFileExisted: false,
                finalManifest: configured,
                stagedProfiles: bound
            ) == nil
        )
    }

    @Test
    func firstSetupOfferStagesPresetsOnlyOnAnExplicitYes() throws {
        try Self.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(Self.firstSetupFile.utf8).write(to: url)
            let configured = Self.manifest(providers: ["Claude Subscription"])

            var accepted = SetupSession(originalManifest: nil)
            accepted.applyQuickSetup(configured)
            var asked: [(label: String, defaultValue: Bool, help: String?)] = []
            try ZenCODESetupRunner.offerBindingPresetsAtFirstSetup(
                session: &accepted,
                finalManifest: configured,
                agentsFileExisted: false,
                presetsURL: url,
                prompt: { label, defaultValue, help in
                    asked.append((label, defaultValue, help))
                    return true
                }
            )

            #expect(asked.count == 1)
            #expect(asked.first?.label == "Apply binding presets from binding-presets.json?")
            #expect(asked.first?.defaultValue == false)
            #expect(asked.first?.help != nil)
            let staged = try #require(accepted.agentProfiles)
            let developer = try #require(staged.first { $0.id == "developer" })
            #expect(developer.modelBindings.map(\.id) == ["claude-binding"])
            #expect(developer.defaultModelBindingID == "claude-binding")
            // The other system profiles have no entry and stay empty.
            #expect(staged.filter { $0.id != "developer" }.allSatisfy { $0.modelBindings.isEmpty })

            var declined = SetupSession(originalManifest: nil)
            declined.applyQuickSetup(configured)
            try ZenCODESetupRunner.offerBindingPresetsAtFirstSetup(
                session: &declined,
                finalManifest: configured,
                agentsFileExisted: false,
                presetsURL: url,
                prompt: { _, _, _ in false }
            )
            #expect(declined.agentProfiles == nil)
        }
    }

    @Test
    func firstSetupOfferStaysSilentWithoutAUsableFileOrOnASecondSetup() throws {
        try Self.withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing.json")
            let invalid = directory.appendingPathComponent("invalid.json")
            try Data("{ not json".utf8).write(to: invalid)
            let valid = directory.appendingPathComponent(AgentBindingPresets.filename)
            try Data(Self.firstSetupFile.utf8).write(to: valid)
            let configured = Self.manifest(providers: ["Claude Subscription"])

            func offer(url: URL, agentsFileExisted: Bool) throws -> (asked: Int, staged: Bool) {
                var session = SetupSession(originalManifest: nil)
                session.applyQuickSetup(configured)
                var asked = 0
                try ZenCODESetupRunner.offerBindingPresetsAtFirstSetup(
                    session: &session,
                    finalManifest: configured,
                    agentsFileExisted: agentsFileExisted,
                    presetsURL: url,
                    prompt: { _, _, _ in
                        asked += 1
                        return true
                    }
                )
                return (asked, session.agentProfiles != nil)
            }

            let missingResult = try offer(url: missing, agentsFileExisted: false)
            #expect(missingResult.asked == 0 && !missingResult.staged)

            let invalidResult = try offer(url: invalid, agentsFileExisted: false)
            #expect(invalidResult.asked == 0 && !invalidResult.staged)

            let existingResult = try offer(url: valid, agentsFileExisted: true)
            #expect(existingResult.asked == 0 && !existingResult.staged)

            let eligibleResult = try offer(url: valid, agentsFileExisted: false)
            #expect(eligibleResult.asked == 1 && eligibleResult.staged)
        }
    }
}
