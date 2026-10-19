import Foundation
import ToolCore

/// Operation-local unified diff. Unlike presentation diffing, both the search
/// and its output are bounded before any evidence escapes the mutation.
enum LocalCompactDiff {
    static let maximumLines = 32 * 1024
    static let maximumEditDistance = 256
    static let maximumComparisonBytes = 16 * 1024 * 1024
    private static let contextLines = 3

    enum Failure: Error, Equatable {
        case byteLimit
        case workLimit
    }

    private struct Source {
        let bytes: [UInt8]
        let lines: [Range<Int>]

        init(_ text: String) throws {
            guard text.utf8.count <= OperationFileChangeRecorder.maximumSnapshotBytes else {
                throw Failure.byteLimit
            }
            bytes = Array(text.utf8)
            var ranges: [Range<Int>] = []
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                guard ranges.count < maximumLines else { throw Failure.workLimit }
                ranges.append(start..<(index + 1))
                start = index + 1
            }
            if start < bytes.count {
                guard ranges.count < maximumLines else { throw Failure.workLimit }
                ranges.append(start..<bytes.count)
            }
            lines = ranges
        }

        subscript(_ index: Int) -> ArraySlice<UInt8> { bytes[lines[index]] }
    }

    private enum Row {
        case context(Int)
        case removal(Int)
        case insertion(Int)

        var isChange: Bool {
            if case .context = self { return false }
            return true
        }
        var consumesOld: Bool {
            if case .insertion = self { return false }
            return true
        }
        var consumesNew: Bool {
            if case .removal = self { return false }
            return true
        }
    }

    static func make(old: String, new: String, maximumBytes: Int) throws -> OperationFileChange.CompactDiff {
        let before = try Source(old)
        let after = try Source(new)
        let rows = try difference(before, after)
        var ranges: [Range<Int>] = []
        var additions = 0
        var deletions = 0
        for (index, row) in rows.enumerated() where row.isChange {
            switch row {
            case .insertion: additions += 1
            case .removal: deletions += 1
            case .context: break
            }
            let range = max(0, index - contextLines)..<min(rows.count, index + contextLines + 1)
            if let previous = ranges.last, previous.upperBound >= range.lowerBound {
                ranges[ranges.count - 1] = previous.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }

        // Appending checks the UTF-8 budget first; a rejected diff is never a
        // truncated hunk with deceptively complete counts.
        var output: [UInt8] = []
        func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
            guard bytes.count <= maximumBytes - output.count else { throw Failure.byteLimit }
            output.append(contentsOf: bytes)
        }
        var cursor = 0
        var oldPosition = 0
        var newPosition = 0
        for range in ranges {
            while cursor < range.lowerBound {
                if rows[cursor].consumesOld { oldPosition += 1 }
                if rows[cursor].consumesNew { newPosition += 1 }
                cursor += 1
            }
            let oldCount = rows[range].filter(\.consumesOld).count
            let newCount = rows[range].filter(\.consumesNew).count
            let oldStart = oldCount == 0 ? oldPosition : oldPosition + 1
            let newStart = newCount == 0 ? newPosition : newPosition + 1
            try append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8)
            for row in rows[range] {
                let marker: UInt8
                let line: ArraySlice<UInt8>
                switch row {
                case let .context(index): marker = 32; line = before[index]
                case let .removal(index): marker = 45; line = before[index]
                case let .insertion(index): marker = 43; line = after[index]
                }
                try append([marker])
                try append(line)
                if line.last != 10 { try append("\n\\ No newline at end of file\n".utf8) }
                if row.consumesOld { oldPosition += 1 }
                if row.consumesNew { newPosition += 1 }
                cursor += 1
            }
        }
        return .init(patch: String(decoding: output, as: UTF8.self), additions: additions, deletions: deletions)
    }

    /// Bounded Myers search, with exact byte comparisons (not Swift's canonical
    /// Unicode equality). The trace is capped independently of source size.
    /// Large rewrites fail closed instead of invoking unbounded CollectionDifference.
    private static func difference(_ old: Source, _ new: Source) throws -> [Row] {
        let oldCount = old.lines.count
        let newCount = new.lines.count
        let distanceLimit = min(maximumEditDistance, oldCount + newCount)
        let offset = distanceLimit + 1
        var frontier = [Int](repeating: 0, count: 2 * distanceLimit + 3)
        var trace: [[Int]] = []
        var remainingComparisons = maximumComparisonBytes
        for distance in 0...distanceLimit {
            trace.append(frontier)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let slot = offset + diagonal
                var x: Int
                if diagonal == -distance || (diagonal != distance && frontier[slot - 1] < frontier[slot + 1]) {
                    x = frontier[slot + 1]
                } else {
                    x = frontier[slot - 1] + 1
                }
                var y = x - diagonal
                while x < oldCount, y < newCount {
                    let lhs = old[x]
                    let rhs = new[y]
                    let cost = lhs.count + rhs.count + 1
                    guard cost <= remainingComparisons else { throw Failure.workLimit }
                    remainingComparisons -= cost
                    guard lhs.elementsEqual(rhs) else { break }
                    x += 1
                    y += 1
                }
                frontier[slot] = x
                if x >= oldCount, y >= newCount {
                    return backtrack(trace, offset: offset, oldCount: oldCount, newCount: newCount)
                }
            }
        }
        throw Failure.workLimit
    }

    private static func backtrack(_ trace: [[Int]], offset: Int, oldCount: Int, newCount: Int) -> [Row] {
        var x = oldCount
        var y = newCount
        var rows: [Row] = []
        for distance in stride(from: trace.count - 1, through: 0, by: -1) {
            let frontier = trace[distance]
            let diagonal = x - y
            let slot = offset + diagonal
            let previousDiagonal: Int
            if diagonal == -distance || (diagonal != distance && frontier[slot - 1] < frontier[slot + 1]) {
                previousDiagonal = diagonal + 1
            } else {
                previousDiagonal = diagonal - 1
            }
            let previousX = frontier[offset + previousDiagonal]
            let previousY = previousX - previousDiagonal
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                rows.append(.context(x))
            }
            if distance > 0 {
                if x == previousX {
                    y -= 1
                    rows.append(.insertion(y))
                } else {
                    x -= 1
                    rows.append(.removal(x))
                }
            }
        }
        return Array(rows.reversed())
    }
}
