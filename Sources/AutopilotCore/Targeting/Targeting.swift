import Foundation
import ApplicationServices
import AppKit

/// Orchestrates element resolution: AX first, vision fallback (Phase 6),
/// with poll-until-resolvable semantics driven by the Poller.
public struct Targeting {
    let axResolver = AXResolver()
    let poller: Poller
    public init(poller: Poller = Poller()) { self.poller = poller }

    /// Resolve a selector to exactly one element, polling until available or timeout.
    /// `baseDir`, when set, is the directory of the plan file; `vision.image`
    /// paths are resolved relative to it (matching `include` semantics).
    public func resolve(_ selector: Selector, app: AXUIElement,
                        timeoutMs: Int, intervalMs: Int, baseDir: URL? = nil) throws -> ElementRef {
        var lastError: Error = TargetingError.timedOut(
            selector: AXResolver.describe(selector), timeoutMs: timeoutMs)
        let ok = poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            do { _ = try axResolver.resolveOne(in: app, selector: selector); return true }
            catch { lastError = error; return false }
        }
        guard ok else {
            // Vision fallback: only if the selector carries a vision block.
            if let vision = selector.vision {
                let imagePath = Self.resolveImagePath(vision.image, baseDir: baseDir)
                // Capture the haystack in-memory at POINT resolution (no temp-PNG
                // leak, and coordinates come back in screen points — so a match
                // is not 2x off on a Retina display).
                let mainID = CGMainDisplayID()
                let screenRect = CGRect(x: 0, y: 0,
                                        width: CGFloat(CGDisplayPixelsWide(mainID)),
                                        height: CGFloat(CGDisplayPixelsHigh(mainID)))
                guard let img = try? ScreenCapture.image(of: screenRect),
                      let haystack = VisionResolver.grayscaleBuffer(of: img),
                      let needle = VisionResolver.grayscaleBuffer(pngPath: imagePath),
                      let match = VisionResolver.bestMatch(haystack: haystack, needle: needle),
                      match.score >= vision.confidence
                else { throw lastError }
                // Top-left + half needle size => center, in screen points.
                let nW = (needle.first?.count ?? 0), nH = needle.count
                return .point(CGPoint(x: match.x + nW / 2, y: match.y + nH / 2))
            }
            throw lastError
        }
        let el = try axResolver.resolveOne(in: app, selector: selector)
        return .ax(el)
    }

    /// Resolve a vision template path: absolute paths are used as-is; relative
    /// paths resolve against the plan's directory (matching `include`), falling
    /// back to the current working directory when no base is known.
    static func resolveImagePath(_ image: String, baseDir: URL?) -> String {
        if image.hasPrefix("/") { return image }
        if let baseDir { return baseDir.appendingPathComponent(image).path }
        return image
    }

    /// Wait for an element to be present (or absent). Returns whether the wait succeeded.
    public func waitForPresence(_ selector: Selector, present: Bool, app: AXUIElement,
                                timeoutMs: Int, intervalMs: Int) -> Bool {
        poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            (axResolver.count(in: app, selector: selector) > 0) == present
        }
    }

    /// The full number of elements matching `selector` (for count assertions);
    /// uses a high stopAt so the count isn't capped at the presence threshold.
    public func matchCount(_ selector: Selector, app: AXUIElement) -> Int {
        axResolver.count(in: app, selector: selector, stopAt: .max)
    }
}
