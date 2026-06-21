import Foundation
import CoreGraphics
import AppKit

/// macOS screen/PNG pixel sampling — the platform half of the old PixelColor.
/// Returns PixelColor.RGB so the pure algebra in core can consume it.
enum MacOSPixelSampler {
    static func sRGBPixels(of image: CGImage) -> [PixelColor.RGB] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [PixelColor.RGB] = []; out.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            out.append(PixelColor.RGB(r: Int(buf[o]), g: Int(buf[o + 1]), b: Int(buf[o + 2])))
        }
        return out
    }
    static func sampleRegion(_ rect: CGRect) -> [PixelColor.RGB] {
        guard let image = try? ScreenCapture.image(of: rect) else { return [] }
        return sRGBPixels(of: image)
    }
    static func loadPNG(_ path: String) -> [PixelColor.RGB]? {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sRGBPixels(of: cg)
    }
    static func sample(at point: CGPoint) -> PixelColor.RGB? {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let image = try? ScreenCapture.image(of: rect) else { return nil }
        return sRGBPixels(of: image).first
    }
}

// TEMPORARY back-compat shim so PlanRunner keeps compiling until Task 9 migrates
// it to the driver. Removed in Task 9.
extension PixelColor {
    static func sampleRegion(_ rect: CGRect) -> [RGB] { MacOSPixelSampler.sampleRegion(rect) }
    static func loadPNG(_ path: String) -> [RGB]? { MacOSPixelSampler.loadPNG(path) }
    static func sample(at point: CGPoint) -> RGB? { MacOSPixelSampler.sample(at: point) }
}
