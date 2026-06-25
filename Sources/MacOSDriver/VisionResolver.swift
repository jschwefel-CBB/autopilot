import Foundation
import CoreGraphics
import AppKit
import AutopilotCore

/// Platform image decoding for template matching: turns PNGs / CGImages into
/// grayscale buffers. The pure NCC `bestMatch` lives in `AutopilotCore.VisionResolver`.
public enum MacVisionDecoder {
    /// Load a PNG file into a grayscale buffer (0...1).
    public static func grayscaleBuffer(pngPath: String) -> [[Double]]? {
        guard let img = NSImage(contentsOfFile: pngPath),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return grayscale(from: cg)
    }

    /// Convert an in-memory CGImage to a grayscale buffer (0...1).
    public static func grayscaleBuffer(of image: CGImage) -> [[Double]]? {
        grayscale(from: image)
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
