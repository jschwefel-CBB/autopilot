import Foundation

/// Deterministic pixel-color algebra. Sampling lives in the platform driver;
/// this file is pure and portable. No LLM — a fixed Euclidean RGB threshold.
public enum PixelColor {
    public struct RGB: Equatable {
        public var r: Int; public var g: Int; public var b: Int   // 0...255
        public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    }

    public static func parseHex(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return RGB(r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF)
    }
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r - b.r), dg = Double(a.g - b.g), db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
    public static func matches(_ actual: RGB, _ expected: RGB, tolerance: Double) -> Bool {
        distance(actual, expected) <= tolerance
    }
    public static func average(of pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        var r = 0, g = 0, b = 0
        for p in pixels { r += p.r; g += p.g; b += p.b }
        let n = pixels.count
        return RGB(r: r / n, g: g / n, b: b / n)
    }
    public static func dominant(of pixels: [RGB], buckets: Int = 16) -> RGB? {
        guard !pixels.isEmpty, buckets > 0 else { return nil }
        let step = 256 / buckets
        func bucket(_ v: Int) -> Int { v / step }
        var counts: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        for p in pixels {
            let key = (bucket(p.r) << 16) | (bucket(p.g) << 8) | bucket(p.b)
            counts[key, default: 0] += 1
            var s = sums[key] ?? (0, 0, 0)
            s.r += p.r; s.g += p.g; s.b += p.b
            sums[key] = s
        }
        let best = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!
        let s = sums[best.key]!, n = best.value
        return RGB(r: s.r / n, g: s.g / n, b: s.b / n)
    }
    public static func diffFraction(_ a: [RGB], _ b: [RGB], perPixelTolerance: Double) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var differing = 0
        for i in a.indices where distance(a[i], b[i]) > perPixelTolerance { differing += 1 }
        return Double(differing) / Double(a.count)
    }
}

/// Bridge between the assertion algebra type and the neutral driver color type.
public extension PixelColor.RGB {
    init(_ c: RGBColor) { self.init(r: c.r, g: c.g, b: c.b) }
    var asRGBColor: RGBColor { RGBColor(r: r, g: g, b: b) }
}
