import Foundation
import ApplicationServices

/// Drives the menu bar by title path, e.g. ["View", "Rainbow Brackets"].
/// This is how menu commands without a key equivalent are invoked — a plain
/// coordinate click cannot open a closed menu.
public struct MenuNavigator {
    public init() {}

    public enum MenuError: Error, CustomStringConvertible {
        case noMenuBar
        case itemNotFound(title: String, available: [String])
        public var description: String {
            switch self {
            case .noMenuBar: return "Application has no menu bar"
            case .itemNotFound(let t, let avail):
                return "Menu item '\(t)' not found. Available: \(avail.joined(separator: ", "))"
            }
        }
    }

    /// Pure helper: among `children`, return the index of the first whose title
    /// equals `title`. Titles are read by the caller; this keeps matching testable.
    public static func indexOfTitle(_ title: String, in titles: [String?]) -> Int? {
        titles.firstIndex { $0 == title }
    }

    /// Walk the menu bar along `path` and press the final item.
    /// `app` is the application AX element.
    public func selectPath(_ path: [String], app: AXUIElement) throws {
        guard !path.isEmpty else { return }
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { throw MenuError.noMenuBar }
        // swiftlint:disable:next force_cast
        var current = menuBar as! AXUIElement

        for (depth, title) in path.enumerated() {
            // Children of a menu-bar item are wrapped in an AXMenu; descend through it.
            let candidates = childMenuItems(of: current)
            let titles = candidates.map { AXTree.string($0, kAXTitleAttribute as String) }
            guard let idx = Self.indexOfTitle(title, in: titles) else {
                throw MenuError.itemNotFound(title: title,
                                             available: titles.compactMap { $0 })
            }
            let item = candidates[idx]
            if depth == path.count - 1 {
                AXTree.press(item)            // leaf: invoke it
            } else {
                AXTree.press(item)            // open the submenu
                current = item
            }
        }
    }

    /// Return the selectable items under a menu-bar item or menu element,
    /// transparently descending through an intervening AXMenu container.
    private func childMenuItems(of element: AXUIElement) -> [AXUIElement] {
        let children = AXTree.children(element)
        // A menu-bar item contains one AXMenu whose children are the items.
        if children.count == 1,
           AXTree.string(children[0], kAXRoleAttribute as String) == (kAXMenuRole as String) {
            return AXTree.children(children[0])
        }
        return children
    }
}
