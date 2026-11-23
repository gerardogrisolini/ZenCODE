import Foundation

/// Pure rules of `read_text`, which reports the texts of a window: which text
/// an element contributes, how it is normalized and bounded, and which entries
/// are dropped. The live Accessibility visit is `DesktopController.readText`;
/// everything it gathers goes through `entries(from:includeDetails:)`.
enum DesktopTextReading {
    /// The longest text of an entry. A longer one is cut, and ends in
    /// `truncationMarker` within this bound, like `DesktopBatchPolicy.shortened`.
    static let maximumTextCharacters = 500
    /// The characters read of an element's value: one more than the longest
    /// text, so that a longer value is known to have been cut.
    static let valueReadLimit = maximumTextCharacters + 1
    static let truncationMarker = "..."

    /// A text kept by `entries(from:includeDetails:)` and whether it was cut.
    struct Entry {
        let item: DesktopTextItem
        let wasTruncated: Bool
    }

    /// Whether `scalar` is noise at either end of a text: a space, a line
    /// break, or an invisible format character (a left-to-right mark, a
    /// zero-width space, a byte order mark). Calculator, for one, prefixes its
    /// display with U+200E.
    private static func isEdgeNoise(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.generalCategory == .format
    }

    /// `text` without the spaces, line breaks, and invisible format characters
    /// at either end; nil when nothing else is left. The inside is unchanged.
    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isEdgeNoise($0) }),
              let last = scalars.lastIndex(where: { !isEdgeNoise($0) }) else {
            return nil
        }
        return String(scalars[first...last])
    }

    /// `text` cut to `maximumTextCharacters` characters, the last three of
    /// which are `truncationMarker`, and whether it was cut.
    static func bounded(_ text: String) -> (text: String, wasTruncated: Bool) {
        guard text.count > maximumTextCharacters else { return (text, false) }
        return (String(text.prefix(maximumTextCharacters - truncationMarker.count)) + truncationMarker, true)
    }

    /// The text an element contributes, before the bound: its value as text
    /// when that is not empty (never for a secure text field), otherwise its
    /// label, the distinct title, description, and placeholder texts joined
    /// with " | " (`DesktopElementPolicy.listLabel`). Nil when there is none.
    static func text(of element: DesktopElementInfo) -> String? {
        if !DesktopElementPolicy.isSecure(role: element.role, subrole: element.subrole),
           let value = normalized(element.value) {
            return value
        }
        return normalized(DesktopElementPolicy.listLabel(of: element))
    }

    /// The texts of `elements`, in order: those with no text are skipped, and
    /// so is a text equal to the one kept just before it (a group repeating the
    /// static text it holds). Each text is bounded. `ref` and `frame` are kept
    /// only with `includeDetails`. The whole list is processed, so an offset
    /// into the result always points at the same entry.
    static func entries(from elements: [DesktopElementInfo], includeDetails: Bool) -> [Entry] {
        var entries: [Entry] = []
        var previous: String?
        for element in elements {
            guard let text = text(of: element), text != previous else { continue }
            previous = text
            let bounded = bounded(text)
            entries.append(Entry(
                item: DesktopTextItem(
                    role: element.role,
                    text: bounded.text,
                    ref: includeDetails ? element.ref : nil,
                    frame: includeDetails ? element.frame : nil
                ),
                wasTruncated: bounded.wasTruncated
            ))
        }
        return entries
    }

    /// The note that tells how many of the returned texts were cut; nil when none was.
    static func truncationNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) text(s) were cut to \(maximumTextCharacters) characters and end in '\(truncationMarker)'."
    }
}
