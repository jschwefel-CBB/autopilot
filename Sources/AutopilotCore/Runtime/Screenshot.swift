import Foundation
import CoreGraphics
import AppKit

public enum Screenshot {
    /// Capture a screen rectangle to a PNG at `path`. Returns true on success.
    @discardableResult
    public static func captureRegion(_ rect: CGRect, to path: String,
                                     metadata: [String: String] = [:]) -> Bool {
        guard let image = try? ScreenCapture.image(of: rect) else { return false }
        return writePNG(image, to: path, metadata: metadata)
    }

    /// Capture the full main display to a PNG at `path`. Returns true on success.
    @discardableResult
    public static func captureMainDisplay(to path: String,
                                          metadata: [String: String] = [:]) -> Bool {
        let displayID = CGMainDisplayID()
        let rect = CGRect(x: 0, y: 0,
                          width: CGFloat(CGDisplayPixelsWide(displayID)),
                          height: CGFloat(CGDisplayPixelsHigh(displayID)))
        guard let image = try? ScreenCapture.image(of: rect) else { return false }
        return writePNG(image, to: path, metadata: metadata)
    }

    /// Capture the frame of an AX element, expanded by `padding` points on all
    /// sides. Returns nil if the element has no frame or capture fails.
    @discardableResult
    public static func captureElement(_ element: AXUIElement, to path: String,
                                      padding: Double = 0,
                                      metadata: [String: String] = [:]) -> Bool {
        guard var frame = AXTree.frame(element) else { return false }
        if padding > 0 { frame = frame.insetBy(dx: -padding, dy: -padding) }
        // Clamp to the display so we never request an out-of-bounds rect.
        let displayID = CGMainDisplayID()
        let display = CGRect(x: 0, y: 0,
                             width: CGFloat(CGDisplayPixelsWide(displayID)),
                             height: CGFloat(CGDisplayPixelsHigh(displayID)))
        frame = frame.intersection(display)
        guard !frame.isNull, !frame.isEmpty else { return false }
        guard let image = try? ScreenCapture.image(of: frame) else { return false }
        return writePNG(image, to: path, metadata: metadata)
    }

    /// Write a CGImage to a PNG file with optional tEXt metadata chunks embedded.
    /// Metadata keys/values become `key = value` tEXt entries — makes the file
    /// self-describing when it lands in an artifacts folder without report.json.
    static func writePNG(_ image: CGImage, to path: String,
                         metadata: [String: String] = [:]) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        var props: [String: Any] = [:]
        if !metadata.isEmpty {
            // PNG tEXt chunks live under kCGImagePropertyPNGDictionary.
            var pngMeta: [String: Any] = [:]
            for (k, v) in metadata { pngMeta[k] = v }
            props[kCGImagePropertyPNGDictionary as String] = pngMeta
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
