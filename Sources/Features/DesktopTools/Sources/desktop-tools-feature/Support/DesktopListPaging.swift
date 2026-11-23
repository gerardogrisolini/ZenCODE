import FeatureKit
import Foundation

/// Pure paging of the lists desktop.run returns (list_apps, list_windows, and
/// list_elements; reusable by any other list): `offset` and `limit`, plus a cut
/// at the response size budget so that a list never reaches the runtime's tool
/// output limit. The callers gather the entries; every decision is made here.
enum DesktopListPaging {
    static let defaultLimit = 100
    static let limitRange = 1...200
    static let offsetRange = 0...DesktopSafetyPolicy.maximumListOffset

    /// One page of a list.
    struct Page<Entry> {
        /// The entries to return: at most `limit`, within the size budget, and
        /// at least one whenever any was offered.
        let entries: [Entry]
        /// The position of the first entry in `entries`.
        let offset: Int
        /// The `offset` that continues the list; nil when no more entries are known.
        let nextOffset: Int?
        /// True when the size budget, not `limit`, ended the page.
        let stoppedByBudget: Bool
    }

    /// `limit` and `offset` of a list action, validated like the other integers.
    static func validated(limit: Int?, offset: Int?) throws -> (limit: Int, offset: Int) {
        let limit = limit ?? defaultLimit
        guard limitRange.contains(limit) else {
            throw DesktopControlError.invalidArgument("limit", "must be between \(limitRange.lowerBound) and \(limitRange.upperBound).")
        }
        let offset = offset ?? 0
        guard offsetRange.contains(offset) else {
            throw DesktopControlError.invalidArgument("offset", "must be between \(offsetRange.lowerBound) and \(offsetRange.upperBound).")
        }
        return (limit, offset)
    }

    /// The characters of an entry encoded as JSON with the encoder of the tool
    /// output (sorted keys, unescaped slashes).
    static func encodedLength(_ entry: any Encodable) -> Int {
        guard let data = try? FeatureProcessProtocol.renderJSON(entry) else { return 0 }
        return String(decoding: data, as: UTF8.self).count
    }

    /// Cuts `entries` into a page.
    ///
    /// - Parameters:
    ///   - entries: the entries from position `offset` on, in order. Giving more
    ///     than `limit` of them tells that the list goes on.
    ///   - offset: the position of `entries[0]` in the whole list.
    ///   - limit: the most entries to return.
    ///   - moreAvailable: whether the list goes on after `entries` (for a caller
    ///     that did not gather the rest).
    ///   - budget: the most characters the returned entries may sum to.
    ///   - size: the characters of one entry.
    ///
    /// The first entry is always returned, even when alone it exceeds the
    /// budget, so a page always progresses.
    static func page<Entry>(
        _ entries: [Entry],
        offset: Int,
        limit: Int,
        moreAvailable: Bool = false,
        budget: Int = DesktopSafetyPolicy.maximumListPayloadCharacters,
        size: (Entry) -> Int
    ) -> Page<Entry> {
        let candidates = entries.prefix(max(limit, 0))
        var used = 0
        var kept = 0
        for entry in candidates {
            let length = size(entry)
            if kept > 0, used + length > budget { break }
            used += length
            kept += 1
        }
        let hasMore = kept < entries.count || moreAvailable
        return Page(
            entries: Array(entries.prefix(kept)),
            offset: offset,
            nextOffset: hasMore ? offset + kept : nil,
            stoppedByBudget: kept < candidates.count
        )
    }

    /// `page(_:offset:limit:moreAvailable:budget:size:)` measuring each entry
    /// as the JSON of the tool output.
    static func page<Entry: Encodable>(
        _ entries: [Entry],
        offset: Int,
        limit: Int,
        moreAvailable: Bool = false,
        budget: Int = DesktopSafetyPolicy.maximumListPayloadCharacters
    ) -> Page<Entry> {
        page(entries, offset: offset, limit: limit, moreAvailable: moreAvailable, budget: budget, size: { encodedLength($0) })
    }

    /// The note that tells why a page stopped and how to continue; nil when the
    /// page is the end of the list.
    ///
    /// - Parameters:
    ///   - noun: the plural of what the list holds, for example "elements".
    ///   - narrowedBy: the arguments that narrow the list, for example "query or role".
    static func note<Entry>(_ page: Page<Entry>, limit: Int, noun: String, narrowedBy: String) -> String? {
        if let next = page.nextOffset {
            if page.stoppedByBudget {
                let count = page.entries.count
                return "Stopped at the response size budget after \(count) \(count == 1 ? "entry" : "entries"); continue with offset=\(next)."
            }
            return "Stopped at limit \(limit); more \(noun) exist. Continue with offset=\(next), or narrow the list with \(narrowedBy)."
        }
        if page.entries.isEmpty, page.offset > 0 {
            return "No \(noun) at offset=\(page.offset); the list ends before it. Use a lower offset."
        }
        return nil
    }

    /// "Listed 12 element(s) from offset 24 in window 'Main'; more remain (next_offset=36)."
    static func summary(noun: String, count: Int, offset: Int, nextOffset: Int?, scope: String? = nil) -> String {
        var text = "Listed \(count) \(noun)"
        if offset > 0 { text += " from offset \(offset)" }
        if let scope { text += " in \(scope)" }
        if let nextOffset { text += "; more remain (next_offset=\(nextOffset))" }
        return text + "."
    }

    /// Notes joined with a space; nil when there is none.
    static func joined(_ notes: [String?]) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }
}
