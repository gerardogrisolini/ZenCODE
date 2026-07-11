import Foundation
@testable import ZenCODECore
import Testing

@Suite("Agent runtime launcher")
struct AgentRuntimeLauncherTests {
    @Test
    func createsProjectAgentsDocumentWhenItIsMissing() throws {
        let workingDirectory = try makeTemporaryWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try AgentRuntimeLauncher.ensureProjectAgentsFileExists(
            workingDirectory: workingDirectory
        )

        let agentsURL = workingDirectory.appendingPathComponent(AgentsContextService.filename)
        #expect(FileManager.default.fileExists(atPath: agentsURL.path))
        #expect(try String(contentsOf: agentsURL, encoding: .utf8).isEmpty == false)
    }

    @Test
    func preservesExistingProjectAgentsDocument() throws {
        let workingDirectory = try makeTemporaryWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let agentsURL = workingDirectory.appendingPathComponent(AgentsContextService.filename)
        let originalContent = "# Existing project instructions\n\nKeep this content.\n"
        try originalContent.write(to: agentsURL, atomically: true, encoding: .utf8)

        try AgentRuntimeLauncher.ensureProjectAgentsFileExists(
            workingDirectory: workingDirectory
        )

        #expect(try String(contentsOf: agentsURL, encoding: .utf8) == originalContent)
    }

    private func makeTemporaryWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-runtime-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
