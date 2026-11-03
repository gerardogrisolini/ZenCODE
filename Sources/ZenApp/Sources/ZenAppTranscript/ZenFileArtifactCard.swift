//
//  ZenFileArtifactCard.swift
//  ZenApp
//
//  One file artifact as a card of the artifacts sidebar, like the file rows
//  of Xcode's navigators: the file name and its folder, the counts, and the
//  explanation and diff behind a disclosure, collapsed at first.
//

import Foundation
import SwiftUI
import ToolCore
import ZenAppTheme

/// One file artifact of the artifacts sidebar. The header shows the
/// disclosure chevron, the status icon, the file name with its folder dimmed
/// after it, and the line counts (or `binary`); the agent that produced the
/// artifact follows when it was a sub-agent. The card starts collapsed: the
/// header reveals the explanation and the diff, as the transcript row does.
public struct ZenFileArtifactCard: View {
    private let artifact: FileChangeArtifact
    private let agentID: String?

    @State private var isExpanded = false
    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - artifact: The file artifact.
    ///   - agentID: The sub-agent that produced the artifact, or `nil` for
    ///     the coordinator.
    public init(artifact: FileChangeArtifact, agentID: String?) {
        self.artifact = artifact
        self.agentID = agentID
    }

    public var body: some View {
        let explanation = ZenFileArtifactPresentation.explanation(of: artifact)
        let canExpand = ZenFileArtifactPresentation.canExpand(artifact, explanation: explanation)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                header(canExpand: canExpand)
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .help(artifact.absolutePath)

            if let agent = agentID.flatMap({ ZenTranscriptText.inline($0, limit: 120) }) {
                Text(AttributedString.zen([
                    ZenTextRun(text: "agent: ", color: palette.textMuted),
                    ZenTextRun(text: agent, color: palette.inlineCodeForeground),
                ]))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Self.detailIndent)
            }

            if isExpanded {
                ZenFileArtifactDetails(artifact: artifact, explanation: explanation)
                    .padding(.leading, Self.detailIndent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenContentCard(cornerRadius: 10, padding: 10)
    }

    /// The indent of the lines under the header: past the disclosure
    /// chevron, as in the transcript row.
    private static let detailIndent: CGFloat = 18

    /// The header row: the disclosure (or its placeholder), the status icon,
    /// the name and folder on one line, and the counts.
    private func header(canExpand: Bool) -> some View {
        let path = Self.nameAndDirectory(of: ZenFileChangeFormatting.displayPath(of: artifact))
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            ZenFileArtifactDisclosure(canExpand: canExpand, isExpanded: isExpanded)
            ZenFileArtifactStatusIcon(status: artifact.status)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ZenTranscriptText.inline(path.name, limit: 1_000) ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.filePath)
                    .layoutPriority(1)
                if let directory = path.directory.flatMap({ ZenTranscriptText.inline($0, limit: 1_000) }) {
                    Text(directory)
                        .foregroundStyle(palette.textMuted)
                }
            }
            .font(ZenFonts.monoSmall)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            if artifact.hasLineCounts {
                Text(AttributedString.zen([
                    ZenTextRun(text: "+\(artifact.additions)", color: palette.fileAddition),
                    ZenTextRun(text: " −\(artifact.deletions)", color: palette.fileDeletion),
                ]))
                .font(ZenFonts.monoSmall)
                .fixedSize()
            }
            if artifact.isBinary {
                Text("binary")
                    .font(.caption)
                    .foregroundStyle(palette.fileMetadata)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
    }

    /// The file name of `path` (its last component) and the folder before
    /// it; `nil` folder for a bare name. A path without a name (`/`) is the
    /// name itself.
    static func nameAndDirectory(of path: String) -> (name: String, directory: String?) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return (path, nil) }
        let directory = (path as NSString).deletingLastPathComponent
        return (name, directory.isEmpty ? nil : directory)
    }
}

#Preview("File artifact cards") {
    VStack(alignment: .leading, spacing: 12) {
        ZenFileArtifactCard(
            artifact: FileChangeArtifact(
                absolutePath: "/tmp/project/Sources/App/App.swift",
                displayPath: "Sources/App/App.swift",
                status: .modified,
                additions: 1,
                deletions: 1,
                oldText: "let a = 1\nlet b = 2\nlet c = 3\n",
                newText: "let a = 1\nlet b = 20\nlet c = 3\n",
                explanation: "Raised the default."
            ),
            agentID: nil
        )
        ZenFileArtifactCard(
            artifact: FileChangeArtifact(
                absolutePath: "/tmp/project/README.md",
                displayPath: "README.md",
                status: .added,
                additions: 2,
                newText: "# Project\nNotes\n"
            ),
            agentID: "agent_132dd052"
        )
        ZenFileArtifactCard(
            artifact: FileChangeArtifact(
                absolutePath: "/tmp/project/Assets/logo.png",
                displayPath: "Assets/logo.png",
                status: .deleted,
                hasLineCounts: false,
                isBinary: true
            ),
            agentID: nil
        )
    }
    .padding()
    .frame(width: 420)
}
