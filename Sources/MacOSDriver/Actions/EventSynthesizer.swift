import Foundation
import CoreGraphics
import ApplicationServices

/// Synthesizes low-level input events via CoreGraphics.
public enum EventSynthesizer {
    /// Brief pause so posted CGEvents are processed as DISCRETE interactions.
    /// Back-to-back down/up with no gap can be coalesced or arrive before the
    /// target's tracking loop is ready — which on a loaded or headless host
    /// (e.g. CI) intermittently drops the click/keystroke (a button's action
    /// never fires; a character is lost). A few ms between phases removes that
    /// race without meaningfully slowing a run.
    private static func settle(_ ms: UInt32 = 12) { usleep(ms * 1000) }

    public static func click(at point: CGPoint, clickCount: Int = 1, rightButton: Bool = false) {
        let button: CGMouseButton = rightButton ? .right : .left
        let down: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        // Move the pointer to the target FIRST so the system's cursor position
        // matches where the click lands — without this, hit-testing can resolve
        // against a stale cursor location and the click activates nothing.
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: button)
        move?.post(tap: .cghidEventTap)
        settle()
        for i in 0..<clickCount {
            let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
            let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
            // Set the click state (1, 2, …) so macOS recognises a real
            // double/triple click — without it, N clicks are seen as N singles
            // and word-select / row-open / rename-activate never fire.
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            d?.post(tap: .cghidEventTap)
            settle()                 // dwell so the press registers as a click
            u?.post(tap: .cghidEventTap)
            if clickCount > 1 { settle() }
        }
    }

    /// Type a string as unicode keyboard events (works regardless of layout).
    public static func type(_ text: String) {
        for ch in text {
            if let (code, shift) = KeyMap.keyCode(for: ch) {
                // Virtual-key events — accepted by field editors (NSSearchField)
                // that ignore keyboardSetUnicodeString events.
                keyChord(virtualKey: code, flags: shift ? .maskShift : [])
            } else {
                typeUnicode(ch)   // fallback for non-ANSI characters
            }
        }
    }

    /// Fallback: synthesize a character via its unicode string (for characters
    /// not in the ANSI keycode map, e.g. accented letters).
    private static func typeUnicode(_ ch: Character) {
        for scalar in ch.unicodeScalars where scalar.value <= 0xFFFF {
            var u = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            down?.post(tap: .cghidEventTap)
            settle()
            up?.post(tap: .cghidEventTap)
            settle()
        }
    }

    /// Press a key chord, e.g. virtualKey for "s" with .maskCommand.
    public static func keyChord(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        settle()                     // hold briefly so the keystroke registers
        up?.post(tap: .cghidEventTap)
        settle()                     // gap before the next key so chars don't drop/reorder
    }

    /// Drag from `from` to `to`: mouse-down, intermediate moves (so apps that
    /// track drag distance register it), then mouse-up at the destination.
    public static func drag(from: CGPoint, to: CGPoint, steps: Int = 10) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: from, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        let n = max(1, steps)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t,
                            y: from.y + (to.y - from.y) * t)
            let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                               mouseCursorPosition: p, mouseButton: .left)
            move?.post(tap: .cghidEventTap)
        }
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: to, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    public static func scroll(dx: Int32, dy: Int32) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }
}
