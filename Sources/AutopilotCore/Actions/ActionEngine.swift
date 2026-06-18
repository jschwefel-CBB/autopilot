import Foundation
import CoreGraphics
import ApplicationServices

public struct ActionEngine {
    public init() {}

    public struct Chord { public var virtualKey: CGKeyCode; public var flags: CGEventFlags }

    /// ANSI virtual key codes: letters, digits, and punctuation.
    static let letterKeyCodes: [Character: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,
        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
        // Punctuation (ANSI layout). `Cmd-,` (Preferences) is the headline case.
        "=":24,"-":27,"]":30,"[":33,"'":39,";":41,"\\":42,",":43,"/":44,
        ".":47,"`":50
    ]
    static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "forwarddelete": 117, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        // Named aliases for punctuation so chords can spell them out.
        "comma": 43, "period": 47, "slash": 44, "semicolon": 41, "quote": 39,
        "leftbracket": 33, "rightbracket": 30, "backslash": 42, "grave": 50,
        "minus": 27, "equal": 24,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    public static func parseChord(_ s: String) throws -> Chord {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let keyToken = parts.last else { throw PlanError.decode("empty key chord") }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: throw PlanError.unsupportedKey("modifier '\(mod)'")
            }
        }
        if let named = namedKeyCodes[keyToken] { return Chord(virtualKey: named, flags: flags) }
        if keyToken.count == 1, let code = letterKeyCodes[keyToken.first!] {
            return Chord(virtualKey: code, flags: flags)
        }
        throw PlanError.unsupportedKey(keyToken)
    }

    /// Center point of an ElementRef for click/type/drag targeting.
    public func point(for ref: ElementRef) -> CGPoint? {
        switch ref {
        case .point(let p): return p
        case .ax(let el):
            guard let f = AXTree.frame(el) else { return nil }
            return CGPoint(x: f.midX, y: f.midY)
        }
    }

    /// Perform a step's action against a resolved element (when applicable).
    /// Returns nothing; throws on unrecoverable failures.
    public func perform(action: Action, args: ActionArgs?, ref: ElementRef?) throws {
        switch action {
        case .click:
            guard let ref, let p = point(for: ref) else { throw PlanError.decode("click needs a point") }
            EventSynthesizer.click(at: p)
        case .doubleClick:
            guard let ref, let p = point(for: ref) else { throw PlanError.decode("doubleClick needs a point") }
            EventSynthesizer.click(at: p, clickCount: 2)
        case .rightClick:
            guard let ref, let p = point(for: ref) else { throw PlanError.decode("rightClick needs a point") }
            EventSynthesizer.click(at: p, rightButton: true)
        case .press:
            guard case .ax(let el)? = ref else { throw PlanError.decode("press needs an AX element") }
            if !AXTree.press(el) { throw PlanError.decode("AX press action failed") }
        case .type:
            guard let text = args?.text else { throw PlanError.decode("type needs text") }
            // Focus the field with a click first — UNLESS focus:false. A focus
            // click drops the first-responder/selection on fields the app has
            // already focused (NSSearchField, an opened rename field), sending
            // the text nowhere. focus:false types into the already-focused field.
            if args?.focus != false, let ref, let p = point(for: ref) {
                EventSynthesizer.click(at: p)
            }
            if args?.clear == true {
                // Select-all (Cmd-A) then delete, so the field starts empty.
                EventSynthesizer.keyChord(virtualKey: 0, flags: .maskCommand)   // Cmd-A ('a' == 0)
                EventSynthesizer.keyChord(virtualKey: 51, flags: [])            // Delete
            }
            EventSynthesizer.type(text)
            if args?.commit == true {
                // Press Return to fire the control's end-editing / target-action,
                // so inline-edit fields (rename, etc.) actually commit the value.
                EventSynthesizer.keyChord(virtualKey: 36, flags: [])            // Return
            }
        case .setValue:
            guard let text = args?.text, case .ax(let el)? = ref else { throw PlanError.decode("setValue needs AX element + text") }
            AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
        case .keyPress:
            guard let keys = args?.keys else { throw PlanError.decode("keyPress needs keys") }
            let chord = try Self.parseChord(keys)
            EventSynthesizer.keyChord(virtualKey: chord.virtualKey, flags: chord.flags)
        case .scroll:
            EventSynthesizer.scroll(dx: Int32(args?.deltaX ?? 0), dy: Int32(args?.deltaY ?? 0))
        case .launch, .terminate, .waitFor, .screenshot, .assert, .assertPixel,
             .assertRegion, .snapshot, .wait, .menu, .drag:
            break // handled by PlanRunner, not here
        }
    }
}
