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
        guard arguments.count == 2 else {
            fputs("usage: MemoryPersistenceTestHelper <workspace> <content>\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            let workspace = URL(fileURLWithPath: arguments[0], isDirectory: true)
            _ = try await MemoryService().writeEntry(
                content: arguments[1],
                workspaceRootURL: workspace
            )
        } catch {
            fputs("MemoryPersistenceTestHelper: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
