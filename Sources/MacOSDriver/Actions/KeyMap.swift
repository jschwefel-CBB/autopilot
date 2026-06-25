import Foundation
import CoreGraphics

/// ANSI virtual-key mappings shared by chord parsing and character typing.
/// Typing via virtual keycodes (rather than `keyboardSetUnicodeString`) is
/// accepted by text controls whose editing happens in a child field editor
/// (e.g. NSSearchField), where unicode-string events otherwise land nowhere.
public enum KeyMap {
    /// Base keycodes for characters reachable without Shift on an ANSI layout.
    public static let unshifted: [Character: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,
        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
        "=":24,"-":27,"]":30,"[":33,"'":39,";":41,"\\":42,",":43,"/":44,
        ".":47,"`":50," ":49,"\t":48,"\n":36
    ]

    /// Characters reached with Shift, mapped to the *base* key's keycode.
    public static let shifted: [Character: CGKeyCode] = [
        "!":18,"@":19,"#":20,"$":21,"%":23,"^":22,"&":26,"*":28,"(":25,")":29,
        "_":27,"+":24,"{":33,"}":30,"|":42,":":41,"\"":39,"<":43,">":47,"?":44,
        "~":50
    ]

    /// Resolve a character to a (keycode, needsShift) pair, or nil if it must
    /// fall back to unicode-string synthesis (e.g. accented/non-ANSI characters).
    public static func keyCode(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
        if let c = unshifted[ch] { return (c, false) }
        if ch.isLetter, ch.isUppercase, let c = unshifted[Character(ch.lowercased())] {
            return (c, true)
        }
        if let c = shifted[ch] { return (c, true) }
        return nil
    }
}
