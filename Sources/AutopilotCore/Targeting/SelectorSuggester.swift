import Foundation

/// Authoring aid: from a snapshot of an app's AX tree, suggest the best selector
/// for each interactive element. Deterministic — pure ranking, no LLM. Output is
/// a suggestion only; the author chooses what to use.
public enum SelectorSuggester {
    public struct Suggestion: Equatable {
        public var role: String
        public var label: String       // a human hint (title/value), may be empty
        public var selector: Selector
        public var note: String        // why this selector / how reliable
    }

    /// Suggest selectors for interactive nodes in `nodes` (as from AXTree.snapshot).
    public static func suggest(from nodes: [[String: String]]) -> [Suggestion] {
        // Count role occurrences so we can add an index when role alone is ambiguous.
        var roleSeen: [String: Int] = [:]
        var out: [Suggestion] = []
        for node in nodes {
            guard let role = node["role"], AXRoles.isInteractive(role) else { continue }
            let id = node["identifier"], title = node["title"], value = node["value"]
            let occurrence = roleSeen[role, default: 0]
            roleSeen[role] = occurrence + 1

            let label = title?.nonEmpty ?? value?.nonEmpty ?? ""
            let selector: Selector
            let note: String
            if let id, !id.isEmpty {
                selector = Selector(identifier: id)
                note = "stable — targets AXIdentifier"
            } else if let t = title?.nonEmpty {
                selector = Selector(role: role, title: t)
                note = "by title — breaks if the title text changes"
            } else {
                selector = Selector(role: role, index: occurrence)
                note = "positional (index \(occurrence)) — fragile; ask the app to set an identifier"
            }
            out.append(Suggestion(role: role, label: label, selector: selector, note: note))
        }
        return out
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
