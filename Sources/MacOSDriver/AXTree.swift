import Foundation
import ApplicationServices

/// Attribute reads + tree traversal over the Accessibility API.
public enum AXTree {
    /// Read a string attribute (e.g. kAXRoleAttribute) or nil.
    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// Read an attribute as a string, coercing numeric values. A checkbox's
    /// `AXValue` is an NSNumber (0/1), not a String, so a plain `string()` read
    /// returns nil; this returns "0"/"1" (etc.) so such state is assertable.
    public static func valueString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // Bools print as 1/0.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            // Distinguish float from integer by the NSNumber's actual stored
            // type (CFNumberIsFloatType), NOT by `===` identity against an int
            // NSNumber — that relies on the small-integer cache, which is an
            // implementation detail that differs across macOS/runner builds and
            // made a float 1.0 read back as "1" (e.g. NSProgressIndicator value).
            if CFNumberIsFloatType(n as CFNumber) { return "\(n.doubleValue)" }
            return "\(n.intValue)"
        }
        return nil
    }

    /// Read a bool attribute, or nil.
    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Read frame (position + size) in screen coordinates, or nil.
    public static func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Immediate children of an element.
    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard err == .success, let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    /// The application-level AX element for a running process. Sets a bounded
    /// messaging timeout so AX IPC to a hung/beachballing target fails fast
    /// (instead of blocking ~6s per call), making the plan's `timeoutMs`
    /// meaningful. Children of this element inherit the timeout.
    public static func application(pid: pid_t, messagingTimeout: Float = 2.0) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /// Perform the AX press action on an element (buttons, menu items, etc.).
    /// More robust than a coordinate click and works for elements that have no
    /// stable on-screen frame (e.g. items in a closed menu). Returns success.
    @discardableResult
    public static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Read the menu-item mark character (e.g. a checkmark) if present.
    /// Menu state is otherwise not observable; this is the one readable signal.
    public static func menuMarkChar(_ element: AXUIElement) -> String? {
        string(element, kAXMenuItemMarkCharAttribute as String)
    }

    /// Result of a walk: whether traversal was cut short by the node cap.
    public struct WalkResult { public var truncated: Bool; public var visited: Int }

    /// Depth-first pre-order walk, invoking `visit` on every descendant
    /// (including `root`). Bounded by `maxNodes`. `visit` returns `true` to
    /// continue or `false` to stop early. Returns whether the cap truncated it.
    @discardableResult
    public static func walk(_ root: AXUIElement, maxNodes: Int = 5000,
                            visit: (AXUIElement) -> Bool) -> WalkResult {
        var stack = [root]
        var count = 0
        while let el = stack.popLast() {
            if !visit(el) { return WalkResult(truncated: false, visited: count) }
            count += 1
            if count >= maxNodes { return WalkResult(truncated: true, visited: count) }
            stack.append(contentsOf: children(el).reversed())
        }
        return WalkResult(truncated: false, visited: count)
    }

    /// A snapshot of the subtree plus whether the node cap truncated it.
    public struct Snapshot { public var nodes: [[String: String]]; public var truncated: Bool }

    /// A JSON-serializable snapshot of the subtree (role/identifier/title/value/frame),
    /// used for failure diagnostics. Carries a `truncated` flag so callers never
    /// mistake a capped walk for a complete one.
    public static func snapshot(_ root: AXUIElement, maxNodes: Int = 2000) -> Snapshot {
        var out: [[String: String]] = []
        let result = walk(root, maxNodes: maxNodes) { el in
            var node: [String: String] = [:]
            if let r = string(el, kAXRoleAttribute as String) { node["role"] = r }
            if let id = string(el, kAXIdentifierAttribute as String) { node["identifier"] = id }
            if let t = string(el, kAXTitleAttribute as String) { node["title"] = t }
            if let v = string(el, kAXValueAttribute as String) { node["value"] = v }
            if let f = frame(el) {
                node["frame"] = "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
            }
            out.append(node)
            return true
        }
        return Snapshot(nodes: out, truncated: result.truncated)
    }
}
