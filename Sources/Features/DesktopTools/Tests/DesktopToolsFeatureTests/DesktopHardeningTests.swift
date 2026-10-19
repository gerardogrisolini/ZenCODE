import FeatureKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopHardeningTests {
    @Test
    func processRunsInRequestedWorkingDirectory() async throws {
        let result = try await DesktopProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/pwd"), arguments: [],
            workingDirectory: URL(fileURLWithPath: "/", isDirectory: true), timeout: 5
        )
        #expect(result.stdoutData == Data("/\n".utf8))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func httpsStaysURL() throws {
        let context = FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let target = try DesktopOpenTarget.resolve("https://x.terminal", context: context, fileExists: { _ in true })
        #expect(target == .url("https://x.terminal"))
    }

    @Test
    func fileURLBecomesExistingPathOrFails() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a b.txt")
        let context = FeatureContext(workingDirectory: dir)
        let raw = file.absoluteString
        #expect(raw.contains("a%20b"))
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopOpenTarget.resolve(raw, context: context, fileExists: { _ in false })
        }
        try Data().write(to: file)
        let target = try DesktopOpenTarget.resolve(raw, context: context, fileExists: { FileManager.default.fileExists(atPath: $0) })
        #expect(target == .file(file.standardizedFileURL.path))
        let literal = try DesktopOpenTarget.resolve("file:///tmp/a%20b.txt", context: context, fileExists: { _ in true })
        #expect(literal == .file("/tmp/a b.txt"))
    }

    @Test
    func relativePathResolvesAgainstContext() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = FeatureContext(workingDirectory: dir)
        var checked: [String] = []
        let target = try DesktopOpenTarget.resolve("sub/doc.txt", context: context, fileExists: { checked.append($0); return true })
        let expected = context.workingDirectory.appendingPathComponent("sub/doc.txt").path
        #expect(target == .file(expected))
        #expect(checked == [expected])
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,hi", "JavaScript:void(0)"])
    func deniedSchemesAreRejected(_ raw: String) {
        let context = FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopOpenTarget.resolve(raw, context: context, fileExists: { _ in true })
        }
    }

    @Test
    func hostWalkFindsFirstApplicationAncestor() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 200, 200: 100]
        let names: [pid_t: String] = [100: "Terminal"]
        let name = DesktopHostApplication.firstApplicationAncestor(
            startingAt: 500, parentOf: { parents[$0] }, applicationName: { names[$0] }
        )
        #expect(name == "Terminal")
        #expect(DesktopHostApplication.firstApplicationAncestor(
            startingAt: 500, parentOf: { parents[$0] }, applicationName: { _ in nil }
        ) == nil)
    }

    @Test
    func hostWalkTerminatesOnCycleAndDepthLimit() {
        #expect(DesktopHostApplication.firstApplicationAncestor(
            startingAt: 10, parentOf: { $0 == 10 ? 20 : 10 }, applicationName: { _ in nil }
        ) == nil)
        var visits = 0
        let result = DesktopHostApplication.firstApplicationAncestor(
            startingAt: 1000, parentOf: { $0 + 1 }, applicationName: { _ in visits += 1; return nil },
            maximumDepth: 5
        )
        #expect(result == nil)
        #expect(visits == 5)
    }

    @Test
    func hostSubjectWording() {
        #expect(DesktopHostApplication.subject(for: "iTerm2") == "iTerm2 (the app that launched zen)")
        #expect(DesktopHostApplication.subject(for: nil) == "the app that launched zen (usually your terminal)")
    }

    @Test
    func zeroTimeoutMeansSingleObservation() {
        #expect(DesktopProbePolicy.isSingleObservation(timeout: 0))
        #expect(!DesktopProbePolicy.isSingleObservation(timeout: 0.5))
    }
}
