import Foundation
import CoreGraphics
import AppKit

public enum Screenshot {
    /// Capture a screen rectangle to a PNG at `path`. Returns true on success.
    @discardableResult
    public static func captureRegion(_ rect: CGRect, to path: String) -> Bool {
        guard let image = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, []) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }

    /// Capture the full main display to a PNG at `path`. Returns true on success.
    @discardableResult
    public static func captureMainDisplay(to path: String) -> Bool {
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch { return false }
    }
}
