import Testing
import Foundation
import CoreGraphics
@testable import AutopilotCore

@Suite struct PixelColorTests {
    @Test func parsesHexWithAndWithoutHash() {
        #expect(PixelColor.parseHex("#FF8800") == PixelColor.RGB(r: 255, g: 136, b: 0))
        #expect(PixelColor.parseHex("ff8800") == PixelColor.RGB(r: 255, g: 136, b: 0))
    }

    @Test func rejectsBadHex() {
        #expect(PixelColor.parseHex("#FFF") == nil)
        #expect(PixelColor.parseHex("nothex") == nil)
    }

    @Test func distanceZeroForIdentical() {
        let c = PixelColor.RGB(r: 10, g: 20, b: 30)
        #expect(PixelColor.distance(c, c) == 0)
    }

    @Test func matchesWithinTolerance() {
        let gold = PixelColor.RGB(r: 255, g: 200, b: 0)
        let nearGold = PixelColor.RGB(r: 250, g: 198, b: 3)
        #expect(PixelColor.matches(nearGold, gold, tolerance: 12))
        #expect(!PixelColor.matches(PixelColor.RGB(r: 0, g: 0, b: 255), gold, tolerance: 12))
    }

    @Test func averageOfPixels() {
        let px = [PixelColor.RGB(r: 0, g: 0, b: 0), PixelColor.RGB(r: 100, g: 200, b: 50)]
        #expect(PixelColor.average(of: px) == PixelColor.RGB(r: 50, g: 100, b: 25))
        #expect(PixelColor.average(of: []) == nil)
    }

    @Test func diffFractionCountsDifferingPixels() {
        let base = Array(repeating: PixelColor.RGB(r: 10, g: 10, b: 10), count: 10)
        var changed = base
        changed[0] = PixelColor.RGB(r: 200, g: 200, b: 200)  // 1 of 10 very different
        #expect(PixelColor.diffFraction(base, changed, perPixelTolerance: 10) == 0.1)
        #expect(PixelColor.diffFraction(base, base, perPixelTolerance: 10) == 0.0)
    }

    @Test func diffFractionMismatchedLengthsIsFullyDifferent() {
        let a = [PixelColor.RGB(r: 0, g: 0, b: 0)]
        let b = [PixelColor.RGB(r: 0, g: 0, b: 0), PixelColor.RGB(r: 0, g: 0, b: 0)]
        #expect(PixelColor.diffFraction(a, b, perPixelTolerance: 0) == 1.0)
    }

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
        let px = MacOSPixelSampler.sRGBPixels(of: img)
        #expect(px.count == 16)
        #expect(PixelColor.matches(px[0], target, tolerance: 4))
    }

    @Test func rgbColorBridgeRoundTrips() {
        let neutral = RGBColor(r: 10, g: 20, b: 30)
        let algebra = PixelColor.RGB(neutral)
        #expect(algebra.r == 10); #expect(algebra.g == 20); #expect(algebra.b == 30)
        #expect(algebra.asRGBColor == neutral)
    }

    @Test func dominantReturnsActualMeanNotBucketCenter() {
        // Pure white must read back as ~255, not the old bucket-center cap of 248.
        let white = Array(repeating: PixelColor.RGB(r: 255, g: 255, b: 255), count: 20)
        let dom = PixelColor.dominant(of: white)!
        #expect(dom == PixelColor.RGB(r: 255, g: 255, b: 255))
    }

    @Test func dominantIgnoresAntiAliasMinority() {
        // 8 gold pixels + 2 near-black edge pixels → dominant ≈ gold, not the
        // average (which the edge pixels would pull down).
        var px = Array(repeating: PixelColor.RGB(r: 230, g: 180, b: 40), count: 8)
        px += [PixelColor.RGB(r: 10, g: 10, b: 10), PixelColor.RGB(r: 20, g: 15, b: 5)]
        let dom = PixelColor.dominant(of: px)!
        #expect(PixelColor.matches(dom, PixelColor.RGB(r: 230, g: 180, b: 40), tolerance: 24))
    }
}
