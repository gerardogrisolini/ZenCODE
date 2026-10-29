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
    func applicableProviderNamesAreTheConfiguredOnesWithABlockInFileOrder() throws {
        let presets = try Self.presets(
            Self.document(providers: [
                (name: "Zeta", bindingID: "z", defaultID: nil),
                (name: "Alpha", bindingID: "a", defaultID: nil),
                (name: "Mid", bindingID: "m", defaultID: nil)
            ])
        )

        // File order and file spelling, whatever the order and case of the
        // configured names; unrelated and empty names never count.
        #expect(
            presets.applicableProviderNames(
                for: [" alpha ", "ZETA", "Unrelated", "", "  "]
            ) == ["Zeta", "Alpha"]
        )
        #expect(
            presets.applicableProviderNames(for: ["Mid", "Alpha", "Zeta"])
                == ["Zeta", "Alpha", "Mid"]
        )
        #expect(presets.applicableProviderNames(for: ["Other", ""]).isEmpty)
        #expect(presets.applicableProviderNames(for: []).isEmpty)

        let documented = try Self.presets(Self.documentedFile)
        #expect(documented.applicableProviderNames(for: ["claude subscription"]) == ["Claude Subscription"])
        #expect(documented.applicableProviderNames(for: ["Other", "OpenRouter"]) == ["OpenRouter"])
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
    func defaultURLIsTheFileShippedWithTheSourceCheckout() throws {
        let checkoutURL = try SwiftFeatureRuntime.zenCODESourceCheckoutURL()
        let url = try #require(AgentBindingPresets.defaultURL())

        #expect(
            url == checkoutURL
                .appendingPathComponent("Sources/ZenPackageMetadata/binding-presets.json")
                .standardizedFileURL
        )
        let presets = try #require(try AgentBindingPresets.load(from: url))
        #expect(!presets.providers.isEmpty)
    }

    // MARK: - Apply binding presets action

    /// Runs the "Apply binding presets" action against a presets file written to
    /// a temporary directory (`nil` leaves it missing). `selectProviders`
    /// stands in for the provider menu; by default it checks every provider,
    /// like confirming the menu with Enter.
    private static func applyBindingPresets(
        to agents: [AgentProfile],
        configuredProviderNames: [String],
        file: String?,
        selectProviders: ([String]) -> Set<String>? = { Set($0) }
    ) throws -> [AgentProfile] {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent(AgentBindingPresets.filename)
            if let file {
                try Data(file.utf8).write(to: url)
            }
            return ZenCODEAgentProfileSetupRunner.applyBindingPresets(
                to: agents,
                configuredProviderNames: configuredProviderNames,
                url: url,
                selectProviders: selectProviders
            )
        }
    }

    /// Records what the provider menu is offered, and answers with `answer`.
    private final class ProviderMenuSpy {
        private(set) var offers: [[String]] = []
        private let answer: ([String]) -> Set<String>?

        init(answer: @escaping ([String]) -> Set<String>? = { Set($0) }) {
            self.answer = answer
        }

        func select(_ names: [String]) -> Set<String>? {
            offers.append(names)
            return answer(names)
        }
    }

    /// Zeta is listed before Alpha. Zeta has entries for the developer and the
    /// reviewer; Alpha only for the developer.
    private static let twoProviderFile = #"""
    { "version": 1, "providers": {
      "Zeta": {
        "developer": { "defaultModelBindingID": "z-dev", "modelBindings": [ { "id": "z-dev", "modelID": "z-dev", "capability": 8 } ] },
        "reviewer": { "modelBindings": [ { "id": "z-rev", "modelID": "z-rev" } ] }
      },
      "Alpha": {
        "developer": { "defaultModelBindingID": "a-dev", "modelBindings": [ { "id": "a-dev", "modelID": "a-dev", "capability": 3 } ] }
      }
    } }
    """#

    private static var previouslyBoundAgents: [AgentProfile] {
        [
            Self.profile(
                id: "developer",
                bindings: [Self.binding("old-dev-1"), Self.binding("old-dev-2")],
                defaultBindingID: "old-dev-2"
            ),
            Self.profile(
                id: "reviewer",
                role: .reviewer,
                name: "Reviewer",
                bindings: [Self.binding("old-rev")],
                defaultBindingID: "old-rev"
            ),
            Self.profile(id: "builder", role: .builder, name: "Builder")
        ]
    }

    @Test
    func applyUsesEveryConfiguredProviderWithABlockInFileOrder() throws {
        let agents = try Self.applyBindingPresets(
            to: Self.previouslyBoundAgents,
            configuredProviderNames: ["Alpha", " zeta ", "Unrelated", ""],
            file: Self.twoProviderFile
        )

        // Both configured providers apply (the profile normalizes the bindings
        // by id); the default is the first provider's in file order, Zeta's,
        // not the first in the configured order.
        #expect(Set(agents[0].modelBindings.map(\.id)) == ["z-dev", "a-dev"])
        #expect(agents[0].defaultModelBindingID == "z-dev")
        #expect(agents[1].modelBindings.map(\.id) == ["z-rev"])
        #expect(agents[2].modelBindings.isEmpty)
    }

    @Test
    func applyReplacesEverythingWithOnlyTheConfiguredProvidersBindings() throws {
        let previous = Self.previouslyBoundAgents

        let alphaOnly = try Self.applyBindingPresets(
            to: previous,
            configuredProviderNames: ["Alpha", "NoBlockInTheFile"],
            file: Self.twoProviderFile
        )

        // The developer gets Alpha's binding and default. The reviewer has no
        // Alpha entry, so the replacement leaves it without bindings or default;
        // so does the builder.
        #expect(alphaOnly[0].modelBindings.map(\.id) == ["a-dev"])
        #expect(alphaOnly[0].modelBindings.first?.capability == 3)
        #expect(alphaOnly[0].defaultModelBindingID == "a-dev")
        #expect(alphaOnly[1].modelBindings.isEmpty)
        #expect(alphaOnly[1].defaultModelBindingID == nil)
        #expect(alphaOnly[2].modelBindings.isEmpty)
        #expect(alphaOnly[2].defaultModelBindingID == nil)

        let zetaOnly = try Self.applyBindingPresets(
            to: previous,
            configuredProviderNames: ["Zeta"],
            file: Self.twoProviderFile
        )
        #expect(zetaOnly[0].modelBindings.map(\.id) == ["z-dev"])
        #expect(zetaOnly[0].defaultModelBindingID == "z-dev")
        #expect(zetaOnly[1].modelBindings.map(\.id) == ["z-rev"])
        // No default declared: the usual profile rule picks the only binding.
        #expect(zetaOnly[1].defaultModelBindingID == "z-rev")
        #expect(zetaOnly[2].modelBindings.isEmpty)

        // Everything but the bindings is preserved.
        for (original, result) in zip(previous, alphaOnly) {
            #expect(result.id == original.id)
            #expect(result.name == original.name)
            #expect(result.instructions == original.instructions)
            #expect(result.role == original.role)
            #expect(result.tools == original.tools)
            #expect(result.skills == original.skills)
        }
    }

    @Test
    func aMissingCheckoutOrAnUnusableFileLeavesTheAgentsUnchanged() throws {
        let previous = Self.previouslyBoundAgents

        #expect(
            ZenCODEAgentProfileSetupRunner.applyBindingPresets(
                to: previous,
                configuredProviderNames: ["Zeta", "Alpha"],
                url: nil,
                selectProviders: { Set($0) }
            ) == previous
        )

        let files: [String?] = [
            nil,
            "{ not json",
            #"{ "version": 2, "providers": {} }"#,
            #"{ "version": 1 }"#
        ]
        for file in files {
            let agents = try Self.applyBindingPresets(
                to: previous,
                configuredProviderNames: ["Zeta", "Alpha"],
                file: file
            )

            #expect(agents == previous, "file: \(file ?? "<missing>")")
        }
    }

    @Test
    func noConfiguredProviderWithABlockLeavesTheAgentsUnchanged() throws {
        let previous = Self.previouslyBoundAgents

        for configured in [["Unrelated"], ["", "  "], []] {
            let agents = try Self.applyBindingPresets(
                to: previous,
                configuredProviderNames: configured,
                file: Self.twoProviderFile
            )

            #expect(agents == previous, "configured: \(configured)")
        }
    }

    // MARK: - Provider selection menu

    @Test
    func theProviderMenuOffersTheConfiguredProvidersWithABlockInFileOrder() throws {
        let menu = ProviderMenuSpy()

        _ = try Self.applyBindingPresets(
            to: Self.previouslyBoundAgents,
            configuredProviderNames: ["Alpha", " zeta ", "Unrelated", ""],
            file: Self.twoProviderFile,
            selectProviders: menu.select
        )

        // Exactly the configured providers that have a block, in the file's
        // spelling and order; unrelated and empty names are never offered.
        #expect(menu.offers == [["Zeta", "Alpha"]])
    }

    @Test
    func selectingASubsetAppliesOnlyThatSubsetWithTotalReplacement() throws {
        let previous = Self.previouslyBoundAgents

        let alphaOnly = try Self.applyBindingPresets(
            to: previous,
            configuredProviderNames: ["Zeta", "Alpha"],
            file: Self.twoProviderFile,
            selectProviders: { _ in ["Alpha"] }
        )

        // Zeta is configured and has a block but was not checked: the developer
        // gets only Alpha's binding and default, and the reviewer, which only
        // Zeta has an entry for, and the builder end up without bindings.
        #expect(alphaOnly[0].modelBindings.map(\.id) == ["a-dev"])
        #expect(alphaOnly[0].defaultModelBindingID == "a-dev")
        #expect(alphaOnly[1].modelBindings.isEmpty)
        #expect(alphaOnly[1].defaultModelBindingID == nil)
        #expect(alphaOnly[2].modelBindings.isEmpty)
        #expect(alphaOnly[2].defaultModelBindingID == nil)

        // An unchecked provider never contributes its default, even when it is
        // first in the file.
        let file = Self.document(providers: [
            (name: "Zeta", bindingID: "z", defaultID: "z"),
            (name: "Alpha", bindingID: "a", defaultID: "a"),
            (name: "Mid", bindingID: "m", defaultID: "m")
        ])
        let subset = try Self.applyBindingPresets(
            to: [Self.profile(id: "developer")],
            configuredProviderNames: ["Zeta", "Alpha", "Mid"],
            file: file,
            selectProviders: { _ in ["Mid", "Alpha"] }
        )
        #expect(Set(subset[0].modelBindings.map(\.id)) == ["a", "m"])
        #expect(subset[0].defaultModelBindingID == "a")
    }

    @Test
    func selectionOrderDoesNotMatterBecausePriorityIsFileOrder() throws {
        // Configured and selected in an order that differs from the file's.
        let selectedBoth = try Self.applyBindingPresets(
            to: Self.previouslyBoundAgents,
            configuredProviderNames: ["Alpha", "Zeta"],
            file: Self.twoProviderFile,
            selectProviders: { _ in ["Alpha", "Zeta"] }
        )
        let reversed = try Self.applyBindingPresets(
            to: Self.previouslyBoundAgents,
            configuredProviderNames: ["Zeta", "Alpha"],
            file: Self.twoProviderFile,
            selectProviders: { _ in ["Zeta", "Alpha"] }
        )

        // Zeta comes first in the file, so its default wins in both cases.
        #expect(selectedBoth[0].defaultModelBindingID == "z-dev")
        #expect(Set(selectedBoth[0].modelBindings.map(\.id)) == ["z-dev", "a-dev"])
        #expect(selectedBoth == reversed)
    }

    @Test
    func anEmptySelectionLeavesTheAgentsUnchanged() throws {
        let previous = Self.previouslyBoundAgents
        let menu = ProviderMenuSpy { _ in [] }

        let agents = try Self.applyBindingPresets(
            to: previous,
            configuredProviderNames: ["Zeta", "Alpha"],
            file: Self.twoProviderFile,
            selectProviders: menu.select
        )

        // Unlike Reset, confirming with nothing checked removes nothing.
        #expect(menu.offers.count == 1)
        #expect(agents == previous)
    }

    @Test
    func cancellingTheProviderMenuLeavesTheAgentsUnchanged() throws {
        let previous = Self.previouslyBoundAgents
        let menu = ProviderMenuSpy { _ in nil }

        let agents = try Self.applyBindingPresets(
            to: previous,
            configuredProviderNames: ["Zeta", "Alpha"],
            file: Self.twoProviderFile,
            selectProviders: menu.select
        )

        #expect(menu.offers.count == 1)
        #expect(agents == previous)
    }

    @Test
    func theProviderMenuIsShownEvenForASingleApplicableProvider() throws {
        let menu = ProviderMenuSpy()

        let agents = try Self.applyBindingPresets(
            to: Self.previouslyBoundAgents,
            configuredProviderNames: ["alpha", "Unrelated"],
            file: Self.twoProviderFile,
            selectProviders: menu.select
        )

        #expect(menu.offers == [["Alpha"]])
        #expect(agents[0].modelBindings.map(\.id) == ["a-dev"])
    }

    @Test
    func theProviderMenuIsNeverShownWhenThereIsNothingToApply() throws {
        let previous = Self.previouslyBoundAgents
        let menu = ProviderMenuSpy()

        // No source checkout.
        #expect(
            ZenCODEAgentProfileSetupRunner.applyBindingPresets(
                to: previous,
                configuredProviderNames: ["Zeta", "Alpha"],
                url: nil,
                selectProviders: menu.select
            ) == previous
        )

        // Missing or invalid file.
        let files: [String?] = [
            nil,
            "{ not json",
            #"{ "version": 2, "providers": {} }"#,
            #"{ "version": 1 }"#
        ]
        for file in files {
            let agents = try Self.applyBindingPresets(
                to: previous,
                configuredProviderNames: ["Zeta", "Alpha"],
                file: file,
                selectProviders: menu.select
            )
            #expect(agents == previous, "file: \(file ?? "<missing>")")
        }

        // No configured provider has a block in the file.
        for configured in [["Unrelated"], ["", "  "], []] {
            let agents = try Self.applyBindingPresets(
                to: previous,
                configuredProviderNames: configured,
                file: Self.twoProviderFile,
                selectProviders: menu.select
            )
            #expect(agents == previous, "configured: \(configured)")
        }

        #expect(menu.offers.isEmpty)
    }

    // MARK: - Reset

    @Test
    func resetRemovesEveryBindingAndDefaultAndKeepsTheOtherFields() {
        let previous = Self.previouslyBoundAgents

        let reset = ZenCODEAgentProfileSetupRunner.resetBindings(of: previous)

        #expect(reset.map(\.id) == previous.map(\.id))
        #expect(reset.allSatisfy { $0.modelBindings.isEmpty })
        #expect(reset.allSatisfy { $0.defaultModelBindingID == nil })
        for (original, result) in zip(previous, reset) {
            #expect(result.name == original.name)
            #expect(result.instructions == original.instructions)
            #expect(result.symbolName == original.symbolName)
            #expect(result.readOnly == original.readOnly)
            #expect(result.role == original.role)
            #expect(result.tools == original.tools)
            #expect(result.skills == original.skills)
        }

        // Resetting again, or agents that never had bindings, changes nothing.
        #expect(ZenCODEAgentProfileSetupRunner.resetBindings(of: reset) == reset)
        #expect(ZenCODEAgentProfileSetupRunner.resetBindings(of: []).isEmpty)
    }
}
