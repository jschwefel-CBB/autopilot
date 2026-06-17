import Foundation
import CoreGraphics
import AppKit

/// Deterministic template matching via normalized cross-correlation.
/// No LLM, no semantic reasoning — a fixed-threshold pixel match returning a point.
public enum VisionResolver {
    public struct Match { public var x: Int; public var y: Int; public var score: Double }

    /// Pure NCC over grayscale buffers. Returns the best top-left match, or nil
    /// if the correlation is undefined (e.g. zero-variance window).
    public static func bestMatch(haystack: [[Double]], needle: [[Double]]) -> Match? {
        let H = haystack.count, W = haystack.first?.count ?? 0
        let h = needle.count, w = needle.first?.count ?? 0
        guard H >= h, W >= w, h > 0, w > 0 else { return nil }

        // Precompute needle mean/variance.
        var nSum = 0.0
        for row in needle { for v in row { nSum += v } }
        let nMean = nSum / Double(h * w)
        var nVar = 0.0
        for row in needle { for v in row { nVar += (v - nMean) * (v - nMean) } }
        guard nVar > 0 else { return nil }

        var best: Match? = nil
        for oy in 0...(H - h) {
            for ox in 0...(W - w) {
                var wSum = 0.0
                for y in 0..<h { for x in 0..<w { wSum += haystack[oy + y][ox + x] } }
                let wMean = wSum / Double(h * w)
                var cov = 0.0, wVar = 0.0
                for y in 0..<h {
                    for x in 0..<w {
                        let a = haystack[oy + y][ox + x] - wMean
                        let b = needle[y][x] - nMean
                        cov += a * b
                        wVar += a * a
                    }
                }
                guard wVar > 0 else { continue }
                let score = cov / (wVar.squareRoot() * nVar.squareRoot())
                if best == nil || score > best!.score {
                    best = Match(x: ox, y: oy, score: score)
                }
            }
        }
        return best
    }

    /// Load a PNG file into a grayscale buffer (0...1).
    public static func grayscaleBuffer(pngPath: String) -> [[Double]]? {
        guard let img = NSImage(contentsOfFile: pngPath),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return grayscale(from: cg)
    }

    static func grayscale(from cg: CGImage) -> [[Double]]? {
        let width = cg.width, height = cg.height
        let cs = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows = Array(repeating: Array(repeating: 0.0, count: width), count: height)
        for y in 0..<height { for x in 0..<width { rows[y][x] = Double(pixels[y * width + x]) / 255.0 } }
        return rows
    }
}
