import Testing
import Foundation
import CoreGraphics
import AutopilotCore
@testable import MacOSDriver

/// Platform pixel-decoding coverage. The pure color algebra (parseHex/distance/
/// matches/average/dominant/diffFraction) is exercised in AutopilotCore's own
/// PixelColorTests; here we cover only the macOS-specific sRGB sampling path.
@Suite struct MacPixelSamplerTests {
    @Test func sRGBPixelsReadsBackSourceColor() throws {
        // A CGImage authored in sRGB must read back as (near) the same RGB after
        // the normalization round-trip — the basis of the color-space fix.
        let target = PixelColor.RGB(r: 52, g: 120, b: 246)   // #3478F6
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 52/255, green: 120/255, blue: 246/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let img = ctx.makeImage()!
        let px = MacPixelSampler.sRGBPixels(of: img)   // -> [RGBColor]
        #expect(px.count == 16)
        // Bridge the neutral driver color into the assertion algebra for compare.
        #expect(PixelColor.matches(PixelColor.RGB(px[0]), target, tolerance: 4))
    }
}
