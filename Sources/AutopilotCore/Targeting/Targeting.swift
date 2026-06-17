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
    public func resolve(_ selector: Selector, app: AXUIElement,
                        timeoutMs: Int, intervalMs: Int) throws -> ElementRef {
        var lastError: Error = TargetingError.timedOut(
            selector: AXResolver.describe(selector), timeoutMs: timeoutMs)
        let ok = poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            do { _ = try axResolver.resolveOne(in: app, selector: selector); return true }
            catch { lastError = error; return false }
        }
        guard ok else {
            // Vision fallback: only if the selector carries a vision block.
            if let vision = selector.vision {
                let shotPath = NSTemporaryDirectory() + "autopilot-vision-\(UUID().uuidString).png"
                guard Screenshot.captureMainDisplay(to: shotPath),
                      let haystack = VisionResolver.grayscaleBuffer(pngPath: shotPath),
                      let needle = VisionResolver.grayscaleBuffer(pngPath: vision.image),
                      let match = VisionResolver.bestMatch(haystack: haystack, needle: needle),
                      match.score >= vision.confidence
                else { throw lastError }
                // Template top-left + half needle size => approximate center, in pixel coords.
                let nW = (needle.first?.count ?? 0), nH = needle.count
                return .point(CGPoint(x: match.x + nW / 2, y: match.y + nH / 2))
            }
            throw lastError
        }
        let el = try axResolver.resolveOne(in: app, selector: selector)
        return .ax(el)
    }

    /// Wait for an element to be present (or absent). Returns whether the wait succeeded.
    public func waitForPresence(_ selector: Selector, present: Bool, app: AXUIElement,
                                timeoutMs: Int, intervalMs: Int) -> Bool {
        poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            (axResolver.count(in: app, selector: selector) > 0) == present
        }
    }
}
