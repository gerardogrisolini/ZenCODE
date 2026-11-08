import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// The response language of delegated agents: the coordinator's locked
/// section reaches their system prompt through the runtime's source, read
/// once per `agent.create` batch, and the generic rule remains without one.
extension DirectSubAgentRuntimeTests {
    private static let lockedItalianSection = SystemPromptBuilder.responseLanguageSection(
        languageName: "Italian"
    )

    private static func developerItem() -> [String: JSONValue] {
        [
            "agents": .array([
                .object([
                    "name": .string("worker"),
                    "profile": .string("Developer"),
                    "prompt": .string("Do the work"),
                ])
            ])
        ]
    }

    @Test
    func delegatedAgentsReceiveTheCoordinatorsLockedResponseLanguage() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let requestedRoots = ResponseLanguageRootRecorder()
            await runtime.updateResponseLanguageSectionProvider { rootSessionID in
                requestedRoots.append(rootSessionID)
                return Self.lockedItalianSection
            }

            _ = try await runtime.createAgents(
                arguments: Self.developerItem(),
                workingDirectory: workspace,
                parentAllowedToolNames: nil,
                rootSessionID: "root-session"
            )

            let session = try #require(await backend.createdSessions().first)
            #expect(session.systemPrompt?.contains(Self.lockedItalianSection) == true)
            #expect(session.systemPrompt?.contains(
                SystemPromptBuilder.responseLanguageSection()
            ) == false)
            #expect(requestedRoots.values == ["root-session"])
            // A taskless child may delegate in turn and reads the same source.
            #expect(await backend.hasResponseLanguageSectionProvider())
            await runtime.shutdown()
        }
    }

    @Test
    func withoutALockedLanguageDelegatedAgentsKeepTheGenericRule() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let backend = CapturingSubAgentRuntimeBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            // The source answers nil while the coordinator has no locked language.
            await runtime.updateResponseLanguageSectionProvider { _ in nil }

            _ = try await runtime.createAgents(
                arguments: Self.developerItem(),
                workingDirectory: workspace,
                parentAllowedToolNames: nil,
                rootSessionID: "root-session"
            )

            let session = try #require(await backend.createdSessions().first)
            #expect(session.systemPrompt?.contains(
                SystemPromptBuilder.responseLanguageSection()
            ) == true)
            #expect(session.systemPrompt?.contains("is locked to") == false)
            await runtime.shutdown()
        }
    }

    @Test
    func aBlankSectionFallsBackToTheGenericRule() {
        let prompt = DirectSubAgentRuntime.systemPrompt(
            name: "worker",
            role: "developer",
            responseLanguageSection: "  \n"
        )
        #expect(prompt.contains(SystemPromptBuilder.responseLanguageSection()))
    }
}

/// Records the root sessions the response-language source is asked for.
private final class ResponseLanguageRootRecorder: Sendable {
    private let roots = Mutex<[String]>([])

    var values: [String] {
        roots.withLock { $0 }
    }

    func append(_ rootSessionID: String) {
        roots.withLock { $0.append(rootSessionID) }
    }
}
