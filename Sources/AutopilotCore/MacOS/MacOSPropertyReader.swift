import Foundation
import ApplicationServices

/// Reads AssertProperty values off a live AX element — the platform half of the
/// old AssertionEngine.readProperty.
enum MacOSPropertyReader {
    static func read(_ property: AssertProperty, from element: AXUIElement) -> String? {
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
            let mark = AXTree.menuMarkChar(element) ?? ""
            return mark.isEmpty ? "false" : "true"
        case .count:
            return nil
        }
    }
}
