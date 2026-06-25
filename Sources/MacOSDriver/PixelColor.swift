import Foundation
import CoreGraphics
import AppKit
import AutopilotCore

/// Platform pixel sampling/decoding: pulls sRGB-normalized pixels off the screen
/// and out of PNGs. The pure color algebra (parse/distance/average/dominant/…)
/// lives in `AutopilotCore.PixelColor`. Returns/consumes core's neutral `RGBColor`.
public enum MacPixelSampler {
    /// Draw a CGImage into a fixed **sRGB** RGBA8 context and return its pixels.
    /// Captured screen pixels arrive in the display's color space (e.g. Display
    /// P3); drawing them into an sRGB context converts them, so an author's sRGB
    /// `#RRGGBB` matches regardless of the display gamut.
    static func sRGBPixels(of image: CGImage) -> [AutopilotCore.RGBColor] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [AutopilotCore.RGBColor] = []; out.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            out.append(AutopilotCore.RGBColor(r: Int(buf[o]), g: Int(buf[o + 1]), b: Int(buf[o + 2])))
        }
        return out
    }

    /// Sample every pixel in a screen rectangle, in sRGB. Returns row-major list.
    public static func sampleRegion(_ rect: CGRect) -> [AutopilotCore.RGBColor] {
        guard let image = try? ScreenCapture.image(of: rect) else { return [] }
        return sRGBPixels(of: image)
    }

    /// Load a PNG into a flat sRGB RGB array (for reference-image comparison).
    /// Normalized through the same sRGB path as live captures so the two compare
    /// in one color space.
    public static func loadPNG(_ path: String) -> [AutopilotCore.RGBColor]? {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sRGBPixels(of: cg)
    }

    /// Read the sRGB color of a single screen pixel at `point`, or nil on failure.
    public static func sample(at point: CGPoint) -> AutopilotCore.RGBColor? {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let image = try? ScreenCapture.image(of: rect) else { return nil }
        return sRGBPixels(of: image).first
    }
}
