//
//  MemoryCitedPathsTests.swift
//  ZenCODECoreTests (memory)
//
//  The stale-path check of recalled memory: which cited paths are reported as
//  missing from the checkout, and which tokens are left alone.
//

import Foundation
import Testing
@testable import ZenCODERuntime

@Suite struct MemoryCitedPathsTests {
    /// A throwaway checkout shaped like this repository: `Sources`, `Docs`,
    /// `Tests` and `Scripts` exist; `Sources/ZenCODERuntime/Memory/Engine`
    /// holds `MemoryAgePolicy.swift`; the root holds the files `Package.swift`,
    /// `AGENTS.md` and `CHANGELOG.md`, and `Docs` holds `memory.md` and
    /// `architecture.md`.
    private struct Checkout {
        let rootURL: URL
        let workspaceURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-cited-paths-\(UUID().uuidString)", isDirectory: true)
            workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
            let fileManager = FileManager.default
            for directory in [
                "Sources/ZenCODERuntime/Memory/Engine",
                "Docs",
                "Tests",
                "Scripts",
                ".github/workflows"
            ] {
                try fileManager.createDirectory(
                    at: workspaceURL.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            for file in [
                "Sources/ZenCODERuntime/Memory/Engine/MemoryAgePolicy.swift",
                "Docs/memory.md",
                "Docs/architecture.md",
                "Scripts/rpios-test.sh",
                ".github/workflows/ci.yml",
                "Package.swift",
                "AGENTS.md",
                "CHANGELOG.md"
            ] {
                try Data("x".utf8).write(to: workspaceURL.appendingPathComponent(file))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func missing(in text: String) -> [String] {
            MemoryCitedPaths.missing(in: text, workspaceRoot: workspaceURL)
        }
    }

    // MARK: - missing(in:workspaceRoot:)

    @Test
    func existingPathIsNotReported() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        #expect(checkout.missing(in: "Summary: see Sources/ZenCODERuntime/Memory/Engine/MemoryAgePolicy.swift:62-65.").isEmpty)
        #expect(checkout.missing(in: "The `Docs/memory.md` guide and the `Sources/ZenCODERuntime/Memory/Engine` folder.").isEmpty)
        #expect(checkout.missing(in: "Hidden folders count too: .github/workflows/ci.yml").isEmpty)
    }

    @Test
    func anchoredMissingPathIsReported() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // The real case: the code lives under ZenCODERuntime, the entry says ZenCODECore.
        let text = """
        Summary: the age policy sits in Sources/ZenCODECore/Memory/Engine, see
        Sources/ZenCODERuntime/Memory/Engine/MemoryAgePolicy.swift:62-65.
        """
        #expect(checkout.missing(in: text) == ["Sources/ZenCODECore/Memory/Engine"])
        #expect(checkout.missing(in: "Run `Scripts/gone.sh` first.") == ["Scripts/gone.sh"])
        #expect(checkout.missing(in: "A deleted doc: Docs/old/guide.md") == ["Docs/old/guide.md"])
    }

    @Test
    func unanchoredTokensAreIgnored() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // Prose slashes, branch names and abbreviations: the first component
        // is not a folder of the checkout, so nothing is claimed about them.
        let text = "Branch feat/x, IT/EN strings, lessicale/semantica ranking, RT/Memory, and/or, Europe/Rome."
        #expect(checkout.missing(in: text).isEmpty)
        // A bare file name carries no folder at all.
        #expect(checkout.missing(in: "Package.swift gone.swift README.md").isEmpty)
    }

    @Test(arguments: [
        "https://example.com/Sources/Gone.swift",
        "file:///Sources/Gone.swift",
        "Sources/**/*.swift",
        "Sources/Gone?.swift",
        "Sources/{Gone,Other}.swift",
        "Sources/[Gone]/x.swift",
        "Sources/<name>/x.swift",
        "Sources/$HOME/x.swift",
        "Sources/gone|other",
        #"Sources\Gone.swift"#,
        "Sources/ZenCODERuntime/Memory…",
        "Sources/ZenCODERuntime/Mem...",
        "Sources/.../Gone.swift",
        "~/Sources/Gone.swift",
        "-Sources/Gone.swift",
        "@Sources/Gone.swift",
        "Sources/../Gone.swift",
        "Sources/Gone.swift=1",
        "path=Sources/Gone.swift"
    ])
    func nonPathTokensAreIgnored(token: String) throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        #expect(checkout.missing(in: "See \(token) for details.").isEmpty)
        #expect(checkout.missing(in: "See `\(token)`.").isEmpty)
    }

    @Test
    func theAnchorMustMatchARootEntryByExactName() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // `Tests`, `Sources` and `Docs` exist; on a case-insensitive file system
        // `tests`, `sources` and `docs` would find them too, so the match is on
        // the names listed from the root, capitals included.
        #expect(checkout.missing(in: "186 tests/29 suites").isEmpty)
        #expect(checkout.missing(in: "sources/tests and docs/SPECULATIVE_DECODING.md of another repository").isEmpty)
        #expect(checkout.missing(in: "SOURCES/Gone.swift DOCS/gone.md").isEmpty)
        // The exact spelling is still checked.
        #expect(checkout.missing(in: "Docs/SPECULATIVE_DECODING.md") == ["Docs/SPECULATIVE_DECODING.md"])
    }

    @Test
    func aFileAnchorOfAMultiComponentTokenIsIgnored() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // A slash used as "and/or" between two file names.
        #expect(checkout.missing(in: "Package.swift/Package.resolved untouched").isEmpty)
        #expect(checkout.missing(in: "AGENTS.md/ARCHITECTURE.md").isEmpty)
        // The same names under a directory anchor are paths.
        #expect(checkout.missing(in: "Docs/AGENTS.md/ARCHITECTURE.md") == ["Docs/AGENTS.md/ARCHITECTURE.md"])
    }

    @Test
    func tokensWithAnAtSignAreIgnored() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // A file at a tag or a revision, not a file of the checkout.
        #expect(checkout.missing(in: "Docs/builder.md@v6.1.1").isEmpty)
        #expect(checkout.missing(in: "see Docs/memory.md@v1.0.0, Sources/Gone.swift@HEAD~1").isEmpty)
        #expect(checkout.missing(in: "Docs/gone.md@v1 Docs/gone.md") == ["Docs/gone.md"])
    }

    @Test
    func extensionlessNamesOfExistingFilesAreProse() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // "Docs/architecture aggiornati": `Docs/architecture.md` exists.
        #expect(checkout.missing(in: "Docs/architecture aggiornati").isEmpty)
        // "Docs/CHANGELOG aggiornati": there is no `Docs/CHANGELOG.*`, but the
        // root holds `CHANGELOG.md`.
        #expect(checkout.missing(in: "Docs/CHANGELOG aggiornati").isEmpty)
        #expect(checkout.missing(in: "`Docs/Package` and `Sources/AGENTS`").isEmpty)

        // No existing entry has that name, or the name carries an extension:
        // these are still reported.
        #expect(checkout.missing(in: "Docs/nothing Docs/architecture.txt Docs/gone.md") == [
            "Docs/nothing",
            "Docs/architecture.txt",
            "Docs/gone.md"
        ])
        #expect(checkout.missing(in: "Sources/Gone") == ["Sources/Gone"])
    }

    @Test
    func stalePathsStayReported() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // The code moved from `ZenCODECore` to `ZenCODERuntime`.
        let moved = "Summary: see Sources/ZenCODECore/Memory/Engine and Sources/ZenCODERuntime/Memory/Engine."
        #expect(checkout.missing(in: moved) == ["Sources/ZenCODECore/Memory/Engine"])
        // A removed file under an existing directory.
        #expect(checkout.missing(in: "Sources/ZenCODERuntime/Memory/Engine/OldPolicy.swift:10-20") == [
            "Sources/ZenCODERuntime/Memory/Engine/OldPolicy.swift"
        ])
        #expect(checkout.missing(in: "Docs/removed.md and Scripts/old.sh") == ["Docs/removed.md", "Scripts/old.sh"])
    }

    @Test
    func lineSuffixesAndFragmentsAreRemovedBeforeTheLookup() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        // Existing files with every supported suffix: nothing to report.
        let existing = """
        Docs/memory.md:12 Docs/memory.md:12-20 Docs/memory.md:12:3 Docs/memory.md#L12 Docs/memory.md#L12-L20
        ./Docs/memory.md ./Docs/memory.md:5 (Docs/memory.md:5), Docs/memory.md#memory-re-embedding.
        """
        #expect(checkout.missing(in: existing).isEmpty)

        // A missing file is reported without the suffix, once.
        let gone = "Docs/gone.md:12 Docs/gone.md:12-20 Docs/gone.md:12:3 Docs/gone.md#L12 Docs/gone.md#L12-L20 ./Docs/gone.md"
        #expect(checkout.missing(in: gone) == ["Docs/gone.md"])
    }

    @Test
    func surroundingPunctuationAndTrailingSlashAreNormalized() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        let text = """
        (Sources/Gone1.swift), "Sources/Gone2.swift". [Sources/Gone3.swift]: 'Sources/Gone4.swift'; <Sources/Gone5.swift>!
        Sources/Gone6/ Sources/Gone6 Tests//Gone7/./x.swift
        """
        #expect(checkout.missing(in: text) == [
            "Sources/Gone1.swift",
            "Sources/Gone2.swift",
            "Sources/Gone3.swift",
            "Sources/Gone4.swift",
            "Sources/Gone5.swift",
            "Sources/Gone6",
            "Tests/Gone7/x.swift"
        ])
        // An existing directory with a trailing slash is not missing.
        #expect(checkout.missing(in: "Sources/ZenCODERuntime/ Docs/ Docs/.").isEmpty)
    }

    @Test
    func absolutePathsAreCheckedOnlyInsideTheWorkspaceRoot() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }
        let root = checkout.workspaceURL.standardizedFileURL.path

        // Inside the root: an existing file passes, a missing one is reported.
        #expect(checkout.missing(in: "\(root)/Docs/memory.md:3").isEmpty)
        #expect(checkout.missing(in: root).isEmpty)
        #expect(checkout.missing(in: "see `\(root)/Docs/gone.md`.") == ["\(root)/Docs/gone.md"])
        // A first component that is not in the checkout does not matter for
        // an absolute path: being under the root is the anchor.
        #expect(checkout.missing(in: "\(root)/elsewhere/gone.md") == ["\(root)/elsewhere/gone.md"])

        // Outside the root: never looked up, even though it does not exist.
        #expect(checkout.missing(in: "/usr/local/nonexistent-\(UUID().uuidString)/file.txt").isEmpty)
        // A sibling that merely shares the textual prefix of the root.
        #expect(checkout.missing(in: "\(root)-sibling/Docs/gone.md").isEmpty)
        // `..` that climbs out of the root.
        #expect(checkout.missing(in: "\(root)/../outside/gone.md").isEmpty)
    }

    @Test
    func duplicatesAreReportedOnceInOrderOfAppearance() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        let text = """
        Docs/b.md then Sources/a.swift then Docs/b.md again, `Sources/a.swift:10`, ./Docs/b.md#L3,
        and finally Tests/c.swift.
        """
        #expect(checkout.missing(in: text) == ["Docs/b.md", "Sources/a.swift", "Tests/c.swift"])
    }

    @Test
    func emptyAndPathFreeTextReportsNothing() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }

        #expect(checkout.missing(in: "").isEmpty)
        #expect(checkout.missing(in: "Summary: nothing cited here.\nState: done.").isEmpty)
    }

    // MARK: - note(forMissing:limit:)

    @Test
    func noteIsNilWhenNothingIsMissing() {
        #expect(MemoryCitedPaths.note(forMissing: []) == nil)
    }

    @Test
    func noteNamesTheMissingPaths() {
        #expect(
            MemoryCitedPaths.note(forMissing: ["a/b.swift"])
                == "Not found in the current checkout (verify before relying on this entry): `a/b.swift`."
        )
        #expect(
            MemoryCitedPaths.note(forMissing: ["Docs/a.md", "Docs/b.md"])
                == "Not found in the current checkout (verify before relying on this entry): `Docs/a.md`, `Docs/b.md`."
        )
    }

    @Test
    func noteCapsTheListAndCountsTheRest() {
        let paths = (1...7).map { "Docs/p\($0).md" }
        #expect(
            MemoryCitedPaths.note(forMissing: paths)
                == "Not found in the current checkout (verify before relying on this entry): "
                + "`Docs/p1.md`, `Docs/p2.md`, `Docs/p3.md`, `Docs/p4.md`, `Docs/p5.md` (+2 more)."
        )
        #expect(
            MemoryCitedPaths.note(forMissing: paths, limit: 2)
                == "Not found in the current checkout (verify before relying on this entry): "
                + "`Docs/p1.md`, `Docs/p2.md` (+5 more)."
        )
        // Exactly at the limit there is no remainder to announce.
        #expect(MemoryCitedPaths.note(forMissing: Array(paths.prefix(5)))?.contains("more") == false)
    }
}
