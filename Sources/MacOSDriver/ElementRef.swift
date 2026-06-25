import Foundation
import ApplicationServices

/// A resolved element: either a live AX element handle, or a screen point
/// (from the vision fallback) when no AX element is available.
public enum ElementRef {
    case ax(AXUIElement)
    case point(CGPoint)
}
