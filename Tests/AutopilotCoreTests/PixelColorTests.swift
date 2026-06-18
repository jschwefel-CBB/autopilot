import Testing
import Foundation
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

    @Test func dominantIgnoresAntiAliasMinority() {
        // 8 gold pixels + 2 near-black edge pixels → dominant ≈ gold, not the
        // average (which the edge pixels would pull down).
        var px = Array(repeating: PixelColor.RGB(r: 230, g: 180, b: 40), count: 8)
        px += [PixelColor.RGB(r: 10, g: 10, b: 10), PixelColor.RGB(r: 20, g: 15, b: 5)]
        let dom = PixelColor.dominant(of: px)!
        #expect(PixelColor.matches(dom, PixelColor.RGB(r: 230, g: 180, b: 40), tolerance: 24))
    }
}
