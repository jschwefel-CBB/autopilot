import Foundation
import ApplicationServices
import AutopilotCore

/// Platform half of assertions: reads an AX element's property as a string.
/// The pure comparison/poll algebra lives in `AutopilotCore.AssertionEngine`.
public struct MacAssertionReader {
    public init() {}

    /// Read the requested property of an AX element as a string.
    public func readProperty(_ property: AssertProperty, from element: AXUIElement) -> String? {
        switch property {
        case .value: return AXTree.valueString(element, kAXValueAttribute as String)
        case .title: return AXTree.string(element, kAXTitleAttribute as String)
        case .enabled: return AXTree.bool(element, kAXEnabledAttribute as String).map { $0 ? "true" : "false" }
        case .focused: return AXTree.bool(element, kAXFocusedAttribute as String).map { $0 ? "true" : "false" }
        case .position:
            guard let f = AXTree.frame(element) else { return nil }
            return "\(Int(f.minX)),\(Int(f.minY))"
        case .size:
            guard let f = AXTree.frame(element) else { return nil }
            return "\(Int(f.width)),\(Int(f.height))"
        case .marked:
            // A non-empty mark char (e.g. a checkmark) means the item is marked.
            let mark = AXTree.menuMarkChar(element) ?? ""
            return mark.isEmpty ? "false" : "true"
        case .count:
            // `count` is resolved by the runner against the whole subtree, not a
            // single element — readProperty is never called for it.
            return nil
        }
    }
}
