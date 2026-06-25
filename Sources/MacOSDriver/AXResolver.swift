import Foundation
import ApplicationServices
import AutopilotCore

/// Resolves a AutopilotCore.Selector against a running app's AX tree (the live-walk half).
/// Pure selector matching/description lives in `AutopilotCore.AXResolver`.
public struct MacAXResolver {
    public init() {}

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
    /// On ambiguity the error lists up to `AXResolver.maxReportedMatches` descriptors.
    /// `path` and `vision` are handled by the Targeting orchestrator, not here.
    /// The walk root for a selector: its `within` parent's subtree if scoped,
    /// else the whole app. Shared by resolveOne/findAll/count so all honor scope.
    func rootFor(_ selector: AutopilotCore.Selector, in appElement: AXUIElement) throws -> AXUIElement {
        guard let parent = selector.withinSelector else { return appElement }
        return try resolveOne(in: appElement, selector: parent)
    }

    public func resolveOne(in appElement: AXUIElement, selector: AutopilotCore.Selector) throws -> AXUIElement {
        // `within`: resolve the parent first, then scope the search to its subtree.
        let root = try rootFor(selector, in: appElement)
        var matches: [AXUIElement] = []
        var descriptors: [String] = []
        let walk = AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) {
                matches.append(el)
                if descriptors.count < AXResolver.maxReportedMatches {
                    descriptors.append(Self.describeNode(el))
                }
            }
            return true   // visit the whole tree (need full count for ambiguity)
        }
        let desc = AXResolver.describe(selector)
        if matches.isEmpty {
            // Distinguish "really absent" from "we stopped looking at the cap" —
            // the latter is a tooling limit, not a missing element.
            if walk.truncated { throw TargetingError.treeTruncated(selector: desc, visited: walk.visited) }
            throw TargetingError.notFound(selector: desc)
        }
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
    public func findAll(in appElement: AXUIElement, selector: AutopilotCore.Selector) -> [String] {
        // Honor `within` scope, like resolveOne. Unresolvable parent → no matches.
        guard let root = try? rootFor(selector, in: appElement) else { return [] }
        var out: [String] = []
        AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) {
                out.append(Self.describeNode(el))
            }
            return true
        }
        return out
    }

    /// Count matches for presence checks, short-circuiting at `stopAt`
    /// (default 2): presence only needs 0 / 1 / "≥2", so there's no need to
    /// finish the walk once we've seen `stopAt` matches.
    public func count(in appElement: AXUIElement, selector: AutopilotCore.Selector, stopAt: Int = 2) -> Int {
        // Honor `within` scope. An unresolvable parent means the scope doesn't
        // exist, so nothing inside it can match → count 0.
        guard let root = try? rootFor(selector, in: appElement) else { return 0 }
        var n = 0
        AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) {
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
}
