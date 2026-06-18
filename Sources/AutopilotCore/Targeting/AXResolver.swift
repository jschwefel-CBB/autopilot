import Foundation
import ApplicationServices

/// Resolves a Selector against a running app's AX tree.
public struct AXResolver {
    public init() {}

    /// Pure predicate: does a snapshot node satisfy the selector?
    /// All present predicates are ANDed. An all-nil selector matches nothing.
    public static func matches(node: [String: String], selector: Selector) -> Bool {
        var anyPredicate = false
        func check(_ value: String?, _ key: String) -> Bool {
            guard let value else { return true }      // predicate absent: no constraint
            anyPredicate = true
            return node[key] == value
        }
        let ok = check(selector.role, "role")
            && check(selector.identifier, "identifier")
            && check(selector.title, "title")
            && check(selector.label, "label")
            && check(selector.value, "value")
        return anyPredicate && ok
    }

    /// How many match descriptors to include in an ambiguity error.
    static let maxReportedMatches = 5

    /// Read the selector-relevant attributes of one element into a snapshot node.
    static func node(of el: AXUIElement) -> [String: String] {
        var node: [String: String] = [:]
        if let r = AXTree.string(el, kAXRoleAttribute as String) { node["role"] = r }
        if let id = AXTree.string(el, kAXIdentifierAttribute as String) { node["identifier"] = id }
        if let t = AXTree.string(el, kAXTitleAttribute as String) { node["title"] = t }
        if let v = AXTree.string(el, kAXValueAttribute as String) { node["value"] = v }
        return node
    }

    /// Resolve to exactly one AX element. Throws on zero or multiple matches.
    /// On ambiguity the error lists up to `maxReportedMatches` descriptors.
    /// `path` and `vision` are handled by the Targeting orchestrator, not here.
    public func resolveOne(in appElement: AXUIElement, selector: Selector) throws -> AXUIElement {
        // `within`: resolve the parent first, then scope the search to its subtree.
        let root: AXUIElement
        if let parent = selector.withinSelector {
            root = try resolveOne(in: appElement, selector: parent)
        } else {
            root = appElement
        }
        var matches: [AXUIElement] = []
        var descriptors: [String] = []
        AXTree.walk(root) { el in
            if Self.matches(node: Self.node(of: el), selector: selector) {
                matches.append(el)
                if descriptors.count < Self.maxReportedMatches {
                    descriptors.append(Self.describeNode(el))
                }
            }
            return true   // visit the whole tree (need full count for ambiguity)
        }
        let desc = Self.describe(selector)
        if matches.isEmpty { throw TargetingError.notFound(selector: desc) }
        // An explicit `index` disambiguates an intentionally-multiple match.
        if let idx = selector.index {
            guard idx >= 0, idx < matches.count else {
                throw TargetingError.notFound(selector: "\(desc) — index \(idx) out of range (\(matches.count) matches)")
            }
            return matches[idx]
        }
        if matches.count > 1 {
            throw TargetingError.ambiguous(selector: desc, count: matches.count, matches: descriptors)
        }
        return matches[0]
    }

    /// Return a human descriptor for every element matching `selector` — the
    /// authoring `find` helper (selector → what it resolves to).
    public func findAll(in appElement: AXUIElement, selector: Selector) -> [String] {
        var out: [String] = []
        AXTree.walk(appElement) { el in
            if Self.matches(node: Self.node(of: el), selector: selector) {
                out.append(Self.describeNode(el))
            }
            return true
        }
        return out
    }

    /// Count matches for presence checks, short-circuiting at `stopAt`
    /// (default 2): presence only needs 0 / 1 / "≥2", so there's no need to
    /// finish the walk once we've seen `stopAt` matches.
    public func count(in appElement: AXUIElement, selector: Selector, stopAt: Int = 2) -> Int {
        var n = 0
        AXTree.walk(appElement) { el in
            if Self.matches(node: Self.node(of: el), selector: selector) {
                n += 1
                if n >= stopAt { return false }   // enough to decide presence
            }
            return true
        }
        return n
    }

    /// A short human descriptor of an element for ambiguity diagnostics.
    static func describeNode(_ el: AXUIElement) -> String {
        let n = node(of: el)
        var parts: [String] = []
        if let r = n["role"] { parts.append(r) }
        if let id = n["identifier"], !id.isEmpty { parts.append("id=\(id)") }
        if let t = n["title"], !t.isEmpty { parts.append("title=\(t)") }
        if let v = n["value"], !v.isEmpty { parts.append("value=\(v.prefix(40))") }
        if let f = AXTree.frame(el) { parts.append("@(\(Int(f.minX)),\(Int(f.minY)))") }
        return parts.joined(separator: " ")
    }

    public static func describe(_ s: Selector) -> String {
        var parts: [String] = []
        if let r = s.role { parts.append("role=\(r)") }
        if let id = s.identifier { parts.append("identifier=\(id)") }
        if let t = s.title { parts.append("title=\(t)") }
        if let l = s.label { parts.append("label=\(l)") }
        if let v = s.value { parts.append("value=\(v)") }
        if let p = s.path { parts.append("path=\(p.joined(separator: "/"))") }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}
