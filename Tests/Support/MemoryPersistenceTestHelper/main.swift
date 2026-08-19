import Foundation
import ZenCODECore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct MemoryPersistenceTestHelper {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3,
              arguments[0] == AppStorageDirectory.testHarnessArgument else {
            FileHandle.standardError.write(Data("usage: MemoryPersistenceTestHelper --zencode-test-harness <workspace> <content>\n".utf8))
            exit(EXIT_FAILURE)
        }

        do {
            let workspace = URL(fileURLWithPath: arguments[1], isDirectory: true)
            _ = try await MemoryService().writeEntry(
                content: arguments[2],
                workspaceRootURL: workspace
            )
        } catch {
            FileHandle.standardError.write(Data("MemoryPersistenceTestHelper: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
