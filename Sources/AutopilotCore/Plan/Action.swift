import Foundation

/// v1 action vocabulary. Lean by design.
public enum Action: String, Codable, Sendable {
    case launch, terminate
    case click, doubleClick, rightClick
    case press          // AX press action (buttons, menu items) — robust vs coordinate click
    case menu           // walk the menu bar: ["View", "Rainbow Brackets"]
    case type, keyPress, setValue, scroll
    case drag           // drag from a source element/point to a destination
    case assertPixel    // assert a screen pixel's color (visual features AX can't see)
    case assertRegion   // assert the average/dominant color over a rectangle (robust for glyphs)
    case snapshot       // capture a region; write a reference on first run, diff on later runs
    case waitFor, screenshot, assert
    case wait   // explicit, discouraged fixed delay
}

/// Per-action arguments. Only the fields relevant to a given action are used.
public struct ActionArgs: Codable, Equatable, Sendable {
    public var text: String?          // type / setValue
    public var keys: String?          // keyPress, e.g. "cmd+s"
    public var deltaX: Int?           // scroll
    public var deltaY: Int?           // scroll
    public var seconds: Double?       // wait
    public var path: String?          // screenshot output path
    public var present: Bool?         // waitFor: true=appears, false=disappears
    public var menuPath: [String]?    // menu: ["View", "Rainbow Brackets"]
    public var to: Selector?          // drag: destination element
    public var toFiles: [String]?     // drag: file paths to drag onto the target (DnD)
    public var commit: Bool?          // type: press Return after typing to fire end-editing
    public var clear: Bool?           // type: select-all + delete before typing
    public var focus: Bool?           // type: click to focus first (default true); set
                                      // false for fields the app already made first responder
    // assertPixel: sample point is target's center + (offsetX,offsetY), or an
    // absolute (atX,atY) when no target is given. Compares to `color` within `tolerance`.
    public var offsetX: Int?
    public var offsetY: Int?
    public var atX: Int?
    public var atY: Int?
    public var color: String?         // expected "#RRGGBB"
    public var tolerance: Double?     // RGB distance tolerance (default 16)
    public var width: Int?            // assertRegion/snapshot: rectangle size
    public var height: Int?
    public var mode: String?          // assertRegion: "average" (default) or "dominant"
    public var reference: String?     // snapshot: reference PNG path (written on first run)
    public var maxDiff: Double?       // snapshot: max allowed differing-pixel fraction (default 0.02)
    public init() {}
}
