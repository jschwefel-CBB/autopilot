import Foundation
import CoreGraphics
import AppKit

/// Deterministic pixel-color sampling and comparison, so visual features that
/// the Accessibility API cannot see (syntax colors, rainbow brackets, gutters)
/// can still be asserted. No LLM — a fixed Euclidean-distance threshold in RGB.
public enum PixelColor {
    public struct RGB: Equatable {
        public var r: Int; public var g: Int; public var b: Int   // 0...255
        public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    }

    /// Parse "#RRGGBB" or "RRGGBB" (case-insensitive) into RGB, or nil.
    public static func parseHex(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return RGB(r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF)
    }

    /// Euclidean distance in RGB space (0 = identical, ~441 = black↔white).
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r - b.r), dg = Double(a.g - b.g), db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Does `actual` match `expected` within `tolerance` (RGB distance)?
    public static func matches(_ actual: RGB, _ expected: RGB, tolerance: Double) -> Bool {
        distance(actual, expected) <= tolerance
    }

    /// The average color of a set of pixels (component-wise mean).
    public static func average(of pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        var r = 0, g = 0, b = 0
        for p in pixels { r += p.r; g += p.g; b += p.b }
        let n = pixels.count
        return RGB(r: r / n, g: g / n, b: b / n)
    }

    /// The dominant color: the most common color after quantizing each channel
    /// into `buckets` bins (default 16), so near-identical anti-aliased shades
    /// collapse together. Deterministic — ties broken by lowest packed value.
    public static func dominant(of pixels: [RGB], buckets: Int = 16) -> RGB? {
        guard !pixels.isEmpty, buckets > 0 else { return nil }
        let step = 256 / buckets
        func quant(_ v: Int) -> Int { min(255, (v / step) * step + step / 2) }
        var counts: [Int: Int] = [:]      // packed quantized RGB -> count
        for p in pixels {
            let key = (quant(p.r) << 16) | (quant(p.g) << 8) | quant(p.b)
            counts[key, default: 0] += 1
        }
        // Most frequent; tie → lowest key for determinism.
        let best = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!
        return RGB(r: (best.key >> 16) & 0xFF, g: (best.key >> 8) & 0xFF, b: best.key & 0xFF)
    }

    /// Draw a CGImage into a fixed **sRGB** RGBA8 context and return its pixels.
    /// Captured screen pixels arrive in the display's color space (e.g. Display
    /// P3); drawing them into an sRGB context converts them, so an author's sRGB
    /// `#RRGGBB` matches regardless of the display gamut.
    static func sRGBPixels(of image: CGImage) -> [RGB] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [RGB] = []; out.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            out.append(RGB(r: Int(buf[o]), g: Int(buf[o + 1]), b: Int(buf[o + 2])))
        }
        return out
    }

    /// Sample every pixel in a screen rectangle, in sRGB. Returns row-major list.
    public static func sampleRegion(_ rect: CGRect) -> [RGB] {
        guard let image = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, []) else { return [] }
        return sRGBPixels(of: image)
    }

    /// Fraction of pixels (0…1) that differ between two equal-length pixel
    /// arrays by more than `perPixelTolerance` (RGB distance). Mismatched
    /// lengths return 1.0 (completely different).
    public static func diffFraction(_ a: [RGB], _ b: [RGB], perPixelTolerance: Double) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var differing = 0
        for i in a.indices where distance(a[i], b[i]) > perPixelTolerance { differing += 1 }
        return Double(differing) / Double(a.count)
    }

    /// Load a PNG into a flat sRGB RGB array (for reference-image comparison).
    /// Normalized through the same sRGB path as live captures so the two compare
    /// in one color space.
    public static func loadPNG(_ path: String) -> [RGB]? {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sRGBPixels(of: cg)
    }

    /// Read the sRGB color of a single screen pixel at `point`, or nil on failure.
    public static func sample(at point: CGPoint) -> RGB? {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let image = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, []) else { return nil }
        return sRGBPixels(of: image).first
    }
}
