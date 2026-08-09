import Foundation
@testable import ZenCODECore
import Testing

@Suite("Core AI local backend")
struct CoreAILocalBackendTests {
    @Test
    func qwenResourcesPathUsesTheConfiguredSupportDirectory() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-coreai-test-\(UUID().uuidString)", isDirectory: true)

        let path = await AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            CoreAILocalModelSupport.qwenResourcesURL()
        }

        #expect(path == supportDirectory
            .appendingPathComponent(CoreAILocalModelSupport.modelsDirectoryName, isDirectory: true)
            .appendingPathComponent(CoreAILocalModelSupport.qwenModelDirectoryName, isDirectory: true)
            .standardizedFileURL)
    }

    @Test
    func localModelIDIsExplicitAndRemoteIDsRemainRemote() {
        #expect(CoreAILocalModelSupport.isLocalModelID(CoreAILocalModelSupport.qwenModelID))
        #expect(CoreAILocalModelSupport.isLocalModelID(" COREAI:QWEN "))
        #expect(!CoreAILocalModelSupport.isLocalModelID("remoteapi:model"))
        #expect(!CoreAILocalModelSupport.isLocalModelID(nil))
    }

    @Test
    func missingLocalResourcesProduceAnActionableErrorWithoutLoadingAModel() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-coreai-missing-\(UUID().uuidString)", isDirectory: true)

        let message = await AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            do {
                let configuration = AgentRuntimeConfiguration(
                    modelID: CoreAILocalModelSupport.qwenModelID,
                    workingDirectory: supportDirectory,
                    maxToolRounds: 1,
                    verboseLogging: false,
                    toolAuthorizationHandler: nil
                )
                _ = try CoreAILocalBackendFactory.makeBackend(
                    configuration: configuration,
                    mcpRuntime: DirectMCPToolRuntime()
                )
                return "backend unexpectedly initialized"
            } catch {
                return error.localizedDescription
            }
        }

        #expect(message.contains("Core AI") || message.contains("macOS 27"))
        #expect(message.contains("Qwen3-0.6B") || message.contains("resources"))
    }
}
