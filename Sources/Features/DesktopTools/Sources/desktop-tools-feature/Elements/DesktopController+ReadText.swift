import ApplicationServices
import Foundation
import ToolCore

/// read_text: the texts of a window, for models that cannot see images. The
/// selection of the window and the filters are those of list_elements; which
/// text each element gives, and what is dropped, is decided by the pure
/// `DesktopTextReading`.
extension DesktopController {
    static func readText(_ input: DesktopRunInput, action: String) throws -> DesktopRunOutput {
        try requireAccessibility()
        prepareAXMessaging()
        guard input.element_ref?.nilIfBlank == nil else {
            throw DesktopControlError.invalidArgument("element_ref", "is not used by read_text; select the window with window_id, pid, bundle_id, or app_name.")
        }
        let (limit, offset) = try DesktopListPaging.validated(limit: input.limit, offset: input.offset)
        let maxDepth = try boundedInteger(input.max_depth ?? 30, name: "max_depth", range: 1...60)
        let roleFilter = try DesktopElementPolicy.normalizedRoleFilter(input.role)
        let query = try DesktopElementPolicy.validatedQuery(input.query)
        let identifier = try DesktopElementPolicy.validatedIdentifier(input.identifier)
        let (scope, window) = elementScope(for: try elementWindowSelection(input))
        // Every element is visited, not only the interactive ones (interactive_only
        // is ignored): static text is what this action is for. Most elements give
        // no text, so the visit is bounded by its node and time budgets, not by a
        // number of matches, and the texts are gathered, deduplicated, and only
        // then paged: the same arguments page through the same sequence.
        let visit = visitElements(
            in: scope, maxDepth: maxDepth, interactiveOnly: false,
            roleFilter: roleFilter, query: query, identifier: identifier,
            valueLimit: DesktopTextReading.valueReadLimit, includeFrameless: true, limit: .max
        )
        let includeDetails = input.include_details ?? false
        let entries = DesktopTextReading.entries(from: visit.matches.map(\.info), includeDetails: includeDetails)
        let page = DesktopListPaging.page(
            Array(entries.dropFirst(offset)), offset: offset, limit: limit,
            size: { DesktopListPaging.encodedLength($0.item) }
        )
        var notes: [String?] = []
        if scope.hostsZen {
            notes.append(DesktopElementPolicy.hostsZenNote(appLabel: scope.appLabel))
        }
        notes.append(visit.budgetNote)
        notes.append(DesktopListPaging.note(page, limit: limit, noun: "texts", narrowedBy: "query, identifier, or role"))
        if visit.unresponsiveNodes > 0 {
            notes.append(DesktopElementPolicy.unresponsiveNote(appName: scope.appLabel, nodes: visit.unresponsiveNodes))
        }
        notes.append(DesktopTextReading.truncationNote(count: page.entries.filter(\.wasTruncated).count))
        if includeDetails, page.entries.contains(where: { $0.item.ref == nil }) {
            notes.append("Some texts have no ref because their window could not be anchored; target them by query or coordinates.")
        }
        let outputWindow = DesktopWindowListing.projected(window)
        return DesktopRunOutput(
            action: action,
            summary: DesktopListPaging.summary(
                noun: "text(s)", count: page.entries.count, offset: offset,
                nextOffset: page.nextOffset, scope: DesktopWindowListing.scopePhrase(outputWindow)
            ),
            window: outputWindow,
            count: page.entries.count,
            next_offset: page.nextOffset,
            note: DesktopListPaging.joined(notes),
            texts: page.entries.map(\.item)
        )
    }
}
