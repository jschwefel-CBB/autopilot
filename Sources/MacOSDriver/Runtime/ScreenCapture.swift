import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// The single screen-capture primitive. Uses ScreenCaptureKit (the supported API
/// on macOS 14+) rather than the deprecated CGWindowListCreateImage /
/// CGDisplayCreateImage. Capture is a blocking leaf operation, so the async SCK
/// call is bridged to sync at this boundary.
public enum ScreenCapture {
    public enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        case noPermission
        case failed(String)
        public var description: String {
            switch self {
            case .noDisplay: return "No capturable display found"
            case .noPermission:
                return "Screen Recording permission denied — grant it in System Settings > Privacy & Security > Screen Recording"
            case .failed(let m): return "Screen capture failed: \(m)"
            }
        }
    }

    /// Capture `rect` (in global screen points) as a CGImage, or throw a typed
    /// error distinguishing "no permission" / "failed" from a real result.
    public static func image(of rect: CGRect) throws -> CGImage {
        // Fail fast and clearly if the permission isn't granted.
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }

        var result: Result<CGImage, Error> = .failure(CaptureError.failed("no result"))
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { displayContains($0, rect) })
                        ?? content.displays.first else {
                    result = .failure(CaptureError.noDisplay); sem.signal(); return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                // Capture only the requested rect, at 1x (point resolution), so
                // returned pixel coordinates correspond to screen points.
                config.sourceRect = displayLocalRect(rect, in: display)
                config.width = max(1, Int(rect.width))
                config.height = max(1, Int(rect.height))
                config.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: config)
                result = .success(img)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch result {
        case .success(let img): return img
        case .failure(let e):
            if let ce = e as? CaptureError { throw ce }
            throw CaptureError.failed(String(describing: e))
        }
    }

    /// Whether a display's frame contains (intersects) the rect.
    private static func displayContains(_ display: SCDisplay, _ rect: CGRect) -> Bool {
        display.frame.intersects(rect)
    }

    /// Convert a global-screen-point rect into the display's local coordinates
    /// (SCStreamConfiguration.sourceRect is relative to the display origin).
    private static func displayLocalRect(_ rect: CGRect, in display: SCDisplay) -> CGRect {
        CGRect(x: rect.origin.x - display.frame.origin.x,
               y: rect.origin.y - display.frame.origin.y,
               width: rect.width, height: rect.height)
    }
}
