import Foundation
import CoreGraphics
import AppKit

/// macOS grayscale decoding for the vision template matcher — the platform half
/// of the old VisionResolver.
enum MacOSImageDecoder {
    static func grayscaleBuffer(pngPath: String) -> [[Double]]? {
        guard let img = NSImage(contentsOfFile: pngPath),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return grayscale(from: cg)
    }
    static func grayscaleBuffer(of image: CGImage) -> [[Double]]? { grayscale(from: image) }
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
