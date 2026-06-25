import Foundation
import ApplicationServices
import CoreGraphics

public struct Permissions {
    public init() {}

    /// Is the running process trusted for Accessibility control?
    public func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    /// Is the process allowed to capture the screen? Required by every visual
    /// action (assertPixel/assertRegion/snapshot/screenshot) and failure shots.
    /// Uses the non-prompting preflight so `doctor` can report it cleanly.
    public func hasScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Human-readable instructions for granting AX permission.
    public func accessibilityInstructions() -> String {
        """
        Accessibility permission required.
        Grant it in: System Settings > Privacy & Security > Accessibility,
        then enable the binary running autopilot (or your terminal app).
        """
    }

    /// Human-readable instructions for granting Screen Recording permission.
    public func screenRecordingInstructions() -> String {
        """
        Screen Recording permission required for visual assertions
        (assertPixel / assertRegion / snapshot / screenshot).
        Grant it in: System Settings > Privacy & Security > Screen Recording,
        then enable the binary running autopilot (or your terminal app).
        """
    }
}
